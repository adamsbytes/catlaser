import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import { auth } from '~/lib/auth.ts';
import { readDeviceAcl } from '~/lib/device-acl.ts';
import type { VerifiedDeviceIdentity } from '~/lib/device-attestation.ts';
import { DeviceAttestationError, verifyDeviceAttestedRequest } from '~/lib/device-attestation.ts';
import {
  DEVICE_PAIRING_CODE_TTL_SECONDS,
  MAX_DEVICE_ID_LENGTH,
  MAX_PAIRING_CODE_LENGTH,
  MIN_PAIRING_CODE_LENGTH,
  exchangePairingCode,
  issuePairingCode,
  listPairedDevicesForUser,
  validateDeviceId,
  validatePairingCode,
} from '~/lib/device-pairing.ts';
import {
  DeviceProvisioningError,
  MAX_DEVICE_NAME_LENGTH,
  PROVISIONING_TOKEN_HEADER,
  provisionDevice,
  provisioningTokenMatches,
} from '~/lib/device-provisioning.ts';
import { env } from '~/lib/env.ts';
import { errorResponse, successResponse } from '~/lib/http.ts';
import { withIdempotentAttestedSession } from '~/lib/idempotency.ts';
import type { IdempotentRouteHandler } from '~/lib/idempotency.ts';
import type { AttestedRouteHandler, RequireAttestedSessionOptions } from '~/lib/protected-route.ts';
import { withAttestedSession } from '~/lib/protected-route.ts';

/**
 * `POST /api/v1/devices/pair` — resolve a scanned QR into a reachable
 * Tailscale endpoint.
 *
 * The wire contract is fixed by the iOS `PairingClient.exchange` call
 * site (see `app/ios/Sources/CatLaserPairing/PairingClient.swift`):
 *
 * - Body: `{ "code": "<base32>", "device_id": "<slug>" }` — no extra
 *   fields, both required.
 * - Headers: `Authorization: Bearer`, `x-device-attestation` with an
 *   `api:<unix_seconds>` binding, and `Idempotency-Key: <uuidv4>`. The
 *   attestation gate + idempotency gate fire in that order via
 *   `withIdempotentAttestedSession`, so a captured bearer alone is
 *   inert and a captured `(bearer, attestation)` pair cannot re-execute
 *   a successful claim within the 60s skew window.
 * - 200 body: `{ device_id, device_name, host, port }`.
 *
 * Mapping (route-local):
 *
 * - 200 — claim succeeded, endpoint returned.
 * - 400 — body missing/extra fields, code/device-id charset or length
 *   violations, Content-Type / parse failures.
 * - 401 — surfaced by the attestation gate (`SESSION_REQUIRED`,
 *   `ATTESTATION_*`). Never emitted from this handler directly.
 * - 404 — unknown code OR code-present-but-device-id-mismatch (same
 *   bucket, by design; see `device-pairing.ts` for the reasoning).
 * - 405 — wrong method. The top-level dispatch in `server.ts` delegates
 *   to this module for any request that matches `/api/v1/devices/pair`
 *   so we can attach an explicit `Allow: POST` header rather than
 *   letting the request fall through to a generic 404.
 * - 409 — code exists and matches, but was already claimed. The user's
 *   QR is single-use — the app's copy needs to come from a fresh QR on
 *   the device.
 * - 410 — code exists and matches, but the issuance window has elapsed.
 *   Same remediation: fresh QR.
 */

export const DEVICES_PAIR_PATH = '/api/v1/devices/pair';

const pairRequestShape = z.strictObject({
  code: z.string().min(1).max(MAX_PAIRING_CODE_LENGTH),
  device_id: z.string().min(1).max(MAX_DEVICE_ID_LENGTH),
});

export type PairErrorCode =
  | 'PAIR_BODY_INVALID'
  | 'PAIR_CODE_INVALID'
  | 'PAIR_DEVICE_ID_INVALID'
  | 'PAIR_CODE_NOT_FOUND'
  | 'PAIR_CODE_ALREADY_USED'
  | 'PAIR_CODE_EXPIRED';

const bodyErrorResponse = (message: string): Response =>
  errorResponse('PAIR_BODY_INVALID', message, 400);

const extractJsonContentType = (request: Request): string | null =>
  request.headers.get('Content-Type')?.split(';')[0]?.trim().toLowerCase() ?? null;

type JsonParseResult =
  | { readonly kind: 'ok'; readonly value: unknown }
  | { readonly kind: 'err'; readonly response: Response };

const parseJsonOrReject = (raw: string): JsonParseResult => {
  try {
    return { kind: 'ok', value: JSON.parse(raw) as unknown };
  } catch (error) {
    const message = error instanceof Error ? error.message : 'JSON parse failed';
    return { kind: 'err', response: bodyErrorResponse(`malformed JSON: ${message}`) };
  }
};

const validateAgainstShape = (
  parsedJson: unknown,
): { readonly code: string; readonly deviceId: string } | Response => {
  const result = pairRequestShape.safeParse(parsedJson);
  if (!result.success) {
    const first = result.error.issues[0];
    const path = first === undefined || first.path.length === 0 ? '<root>' : first.path.join('.');
    const message = first === undefined ? 'body failed validation' : first.message;
    return bodyErrorResponse(`${path}: ${message}`);
  }
  return { code: result.data.code, deviceId: result.data.device_id };
};

const parseJsonBodyOrReject = async (
  request: Request,
): Promise<{ readonly code: string; readonly deviceId: string } | Response> => {
  const contentType = extractJsonContentType(request);
  if (contentType !== 'application/json') {
    return bodyErrorResponse(`Content-Type must be application/json, got '${contentType ?? ''}'`);
  }
  const raw = await request.text();
  if (raw.length === 0) {
    return bodyErrorResponse('request body is empty');
  }
  const parsed = parseJsonOrReject(raw);
  if (parsed.kind === 'err') {
    return parsed.response;
  }
  return validateAgainstShape(parsed.value);
};

const pairHandler: IdempotentRouteHandler = async (request, session) => {
  const parsed = await parseJsonBodyOrReject(request);
  if (parsed instanceof Response) {
    return parsed;
  }

  // Character-set / length validation runs on the wire values before
  // we hash and look up. A client that passes Zod's shape but sends a
  // code with a space, a device-id with a `.`, etc., is rejected with a
  // distinct machine-readable code so the UI surface can tell "QR not
  // recognised" from "server rejected syntactically valid input".
  const codeError = validatePairingCode(parsed.code);
  if (codeError !== null) {
    return errorResponse('PAIR_CODE_INVALID', `code failed validation: ${codeError}`, 400);
  }
  const deviceError = validateDeviceId(parsed.deviceId);
  if (deviceError !== null) {
    return errorResponse(
      'PAIR_DEVICE_ID_INVALID',
      `device_id failed validation: ${deviceError}`,
      400,
    );
  }

  const outcome = await exchangePairingCode({
    code: parsed.code,
    deviceId: parsed.deviceId,
    userId: session.user.id,
    sessionId: session.session.id,
  });

  switch (outcome.kind) {
    case 'ok':
      return successResponse({
        device_id: outcome.device.deviceId,
        device_name: outcome.device.deviceName,
        host: outcome.device.host,
        port: outcome.device.port,
        // Ed25519 public key the device signs AuthResponse with.
        // Emitted as base64url-no-pad — the exact shape the iOS
        // verifier's `Curve25519.Signing.PublicKey(rawRepresentation:)`
        // expects after url-safe decoding.
        device_public_key: outcome.device.publicKeyEd25519,
      });
    case 'not_found':
      return errorResponse(
        'PAIR_CODE_NOT_FOUND',
        'pairing code is not recognised for this device',
        404,
      );
    case 'already_used':
      return errorResponse(
        'PAIR_CODE_ALREADY_USED',
        'pairing code has already been claimed; generate a fresh QR on the device',
        409,
      );
    case 'expired':
      return errorResponse(
        'PAIR_CODE_EXPIRED',
        'pairing code has expired; generate a fresh QR on the device',
        410,
      );
    default: {
      const exhaustive: never = outcome;
      throw new Error(`unreachable pairing outcome: ${JSON.stringify(exhaustive)}`);
    }
  }
};

const PAIR_ALLOWED_METHODS = ['POST'] as const;

const pairMethodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed on ${DEVICES_PAIR_PATH}; accepted methods are ${PAIR_ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', PAIR_ALLOWED_METHODS.join(', '));
  return response;
};

/**
 * Compose the device-pair route against a specific auth instance and
 * optional clock override. Tests use this to drive the handler under a
 * `createAuth({ attestationNowSeconds: ... })` fixture with a frozen
 * clock; production wires the module-level `auth` singleton via the
 * default `devicesPairRoute` export below.
 */
export const buildDevicesPairRoute = (
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  const guardedPairHandler = withIdempotentAttestedSession(pairHandler, options);
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') {
      return pairMethodNotAllowed(request.method);
    }
    return await guardedPairHandler(request);
  };
};

export const devicesPairRoute = buildDevicesPairRoute({ auth });

/**
 * `GET /api/v1/devices/paired` — list the signed-in user's active,
 * non-revoked paired devices.
 *
 * The iOS app calls this on launch (and periodically thereafter) to
 * verify that its locally cached `PairedDevice` row is still the
 * current claim server-side. A re-pair of the same physical device by
 * a different user, a user-initiated unpair from another surface, or
 * any other supersession flips the prior row's `revoked_at` column in
 * `exchangePairingCode`; those rows are excluded here. An app whose
 * cached device_id is absent from the response must wipe its Keychain
 * row and force the user back through pairing.
 *
 * Wire contract:
 *
 * ```
 * GET /api/v1/devices/paired
 * Authorization: Bearer <session bearer>
 * x-device-attestation: <api:<ts> signed payload>
 *
 * 200 OK, application/json:
 * {
 *   "devices": [
 *     { "device_id": "<slug>", "device_name": "<display>|null",
 *       "host": "<tailscale host>", "port": <uint16>,
 *       "paired_at": "<ISO-8601>" },
 *     ...
 *   ]
 * }
 * ```
 *
 * Read-only, no body, no idempotency key. Gated by the protected-route
 * attestation middleware only.
 */

export const DEVICES_PAIRED_PATH = '/api/v1/devices/paired';

const pairedListHandler: AttestedRouteHandler = async (_request, session) => {
  const devices = await listPairedDevicesForUser(session.user.id);
  return successResponse({
    devices: devices.map((paired) => ({
      device_id: paired.deviceId,
      device_name: paired.deviceName,
      host: paired.host,
      port: paired.port,
      paired_at: paired.pairedAt.toISOString(),
      // Ed25519 public key used to verify the device's AuthResponse
      // signatures on every TCP handshake. Same shape as the pair
      // endpoint emits.
      device_public_key: paired.publicKeyEd25519,
    })),
  });
};

const PAIRED_ALLOWED_METHODS = ['GET'] as const;

const pairedMethodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed on ${DEVICES_PAIRED_PATH}; accepted methods are ${PAIRED_ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', PAIRED_ALLOWED_METHODS.join(', '));
  return response;
};

/**
 * Compose the paired-devices route against a specific auth instance
 * and optional clock override. Matches the `buildDevicesPairRoute`
 * pattern so tests can frame-freeze the clock and swap the auth
 * fixture in without touching the module-level singleton.
 */
export const buildDevicesPairedRoute = (
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  const guarded = withAttestedSession(pairedListHandler, options);
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'GET') {
      return pairedMethodNotAllowed(request.method);
    }
    return await guarded(request);
  };
};

export const devicesPairedRoute = buildDevicesPairedRoute({ auth });

// ---------------------------------------------------------------------------
// Device-facing routes (POST /provision, POST /:slug/pairing-code,
// GET /:slug/acl)
//
// These routes are gated by the device's own authentication, not by a
// user bearer + SE attestation. See `device-attestation.ts` for the
// Ed25519 handshake spec. `/provision` is the one-shot exception —
// authenticated by the pre-shared `PROVISIONING_TOKEN` — because the
// device's Ed25519 public key is WHAT that call publishes. Every
// other device-originating call runs through
// `verifyDeviceAttestedRequest`.
// ---------------------------------------------------------------------------

/** `POST /api/v1/devices/provision` — factory device registration. */
export const DEVICES_PROVISION_PATH = '/api/v1/devices/provision';

/**
 * `POST /api/v1/devices/:slug/pairing-code` — device-gated issuance.
 * Matched dynamically by `matchDevicePairingCodeRoute`. The device's
 * own Ed25519 key authenticates; the server mints a fresh 160-bit
 * base32 pairing code, stores the hash, returns plaintext to the
 * device. The plaintext is also rendered into the QR the device
 * displays to the user.
 */
export const DEVICES_PAIRING_CODE_PATH_PREFIX = '/api/v1/devices/';
export const DEVICES_PAIRING_CODE_PATH_SUFFIX = '/pairing-code';
export const DEVICES_ACL_PATH_SUFFIX = '/acl';

// --- /provision ------------------------------------------------------------

const provisionRequestShape = z.strictObject({
  device_id: z.string().min(1).max(MAX_DEVICE_ID_LENGTH),
  public_key_ed25519: z.string().min(1).max(256),
  tailscale_host: z.string().min(1).max(253),
  tailscale_port: z.number().int(),
  device_name: z.string().min(1).max(MAX_DEVICE_NAME_LENGTH).optional(),
});

type ProvisioningErrorCode =
  | 'PROVISIONING_TOKEN_REQUIRED'
  | 'PROVISIONING_TOKEN_INVALID'
  | 'PROVISIONING_BODY_INVALID';

const provisioningErrorResponse = (
  code: ProvisioningErrorCode,
  message: string,
  status: number,
): Response => errorResponse(code, message, status);

type ProvisionBodyResult =
  | { readonly value: z.infer<typeof provisionRequestShape> }
  | { readonly error: Response };

type JsonBodyResult =
  | { readonly kind: 'ok'; readonly value: unknown }
  | { readonly kind: 'err'; readonly response: Response };

const readProvisionJsonBody = async (request: Request): Promise<JsonBodyResult> => {
  const contentType = request.headers.get('Content-Type')?.split(';')[0]?.trim().toLowerCase();
  if (contentType !== 'application/json') {
    return {
      kind: 'err',
      response: provisioningErrorResponse(
        'PROVISIONING_BODY_INVALID',
        `Content-Type must be application/json, got '${contentType ?? ''}'`,
        400,
      ),
    };
  }
  const raw = await request.text();
  if (raw.length === 0) {
    return {
      kind: 'err',
      response: provisioningErrorResponse(
        'PROVISIONING_BODY_INVALID',
        'request body is empty',
        400,
      ),
    };
  }
  try {
    return { kind: 'ok', value: JSON.parse(raw) as unknown };
  } catch (error) {
    const message = error instanceof Error ? error.message : 'JSON parse failed';
    return {
      kind: 'err',
      response: provisioningErrorResponse(
        'PROVISIONING_BODY_INVALID',
        `malformed JSON: ${message}`,
        400,
      ),
    };
  }
};

const parseProvisionBody = async (request: Request): Promise<ProvisionBodyResult> => {
  const parsed = await readProvisionJsonBody(request);
  if (parsed.kind === 'err') {
    return { error: parsed.response };
  }
  const result = provisionRequestShape.safeParse(parsed.value);
  if (!result.success) {
    const first = result.error.issues[0];
    const path = first === undefined || first.path.length === 0 ? '<root>' : first.path.join('.');
    const message = first === undefined ? 'body failed validation' : first.message;
    return {
      error: provisioningErrorResponse('PROVISIONING_BODY_INVALID', `${path}: ${message}`, 400),
    };
  }
  return { value: result.data };
};

const enforceProvisioningMethod = (request: Request): Response | null => {
  if (request.method === 'POST') {
    return null;
  }
  const response = errorResponse(
    'method_not_allowed',
    `Method ${request.method} is not allowed on ${DEVICES_PROVISION_PATH}`,
    405,
  );
  response.headers.set('Allow', 'POST');
  return response;
};

const enforceProvisioningToken = (request: Request): Response | null => {
  const presented = request.headers.get(PROVISIONING_TOKEN_HEADER)?.trim() ?? '';
  if (presented.length === 0) {
    return provisioningErrorResponse(
      'PROVISIONING_TOKEN_REQUIRED',
      `missing or empty ${PROVISIONING_TOKEN_HEADER} header`,
      401,
    );
  }
  if (!provisioningTokenMatches(presented, env.PROVISIONING_TOKEN)) {
    return provisioningErrorResponse(
      'PROVISIONING_TOKEN_INVALID',
      'provisioning token did not match',
      401,
    );
  }
  return null;
};

const callProvisionDevice = async (
  input: z.infer<typeof provisionRequestShape>,
): Promise<Response> => {
  try {
    const result = await provisionDevice({
      slug: input.device_id,
      publicKeyEd25519: input.public_key_ed25519,
      tailscaleHost: input.tailscale_host,
      tailscalePort: input.tailscale_port,
      deviceName: input.device_name ?? null,
    });
    return successResponse(
      { device_id: result.slug, created: result.isNew },
      { status: result.isNew ? 201 : 200 },
    );
  } catch (error) {
    if (error instanceof DeviceProvisioningError) {
      return provisioningErrorResponse('PROVISIONING_BODY_INVALID', error.message, 400);
    }
    throw error;
  }
};

export const devicesProvisionRoute = async (request: Request): Promise<Response> => {
  const methodRejection = enforceProvisioningMethod(request);
  if (methodRejection !== null) {
    return methodRejection;
  }
  const tokenRejection = enforceProvisioningToken(request);
  if (tokenRejection !== null) {
    return tokenRejection;
  }
  const parsed = await parseProvisionBody(request);
  if ('error' in parsed) {
    return parsed.error;
  }
  return await callProvisionDevice(parsed.value);
};

// --- device-attested routes (pairing-code issuance + ACL poll) -------------

/**
 * Options for composing the device-attested routes. Mirrors
 * `RequireAttestedSessionOptions` in shape: tests override the clock
 * so skew assertions are deterministic.
 */
export interface RequireDeviceAttestedOptions {
  readonly nowSeconds?: () => number;
}

type DeviceRouteHandler = (
  request: Request,
  device: VerifiedDeviceIdentity,
) => Response | Promise<Response>;

const withDeviceAttestation = (
  handler: DeviceRouteHandler,
  options: RequireDeviceAttestedOptions,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    let identity: VerifiedDeviceIdentity;
    try {
      identity = await verifyDeviceAttestedRequest(request, options);
    } catch (error) {
      if (error instanceof DeviceAttestationError) {
        return errorResponse(error.code, error.message, error.status);
      }
      throw error;
    }
    return await handler(request, identity);
  };
};

/**
 * Generate a fresh 160-bit opaque pairing code as an uppercase
 * base32 string (32 chars, no padding). Matches the iOS parser's
 * expectations (`[A-Z2-7]{16..128}`).
 */
const generatePairingCode = (): string => {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const bytes = randomBytes(20); // 160 bits of entropy
  // 5-bit-at-a-time accumulator over the 20-byte input. 160 bits /
  // 5 bits per symbol = 32 base32 chars, exactly — no residual bits,
  // no padding needed. Bit-shift operators are the clear expression
  // of "5 bits of packed state"; the eslint-disables below are for
  // this specific encoder, not a blanket permission.
  let out = '';
  let buffer = 0;
  let bitsInBuffer = 0;
  for (const byte of bytes) {
    // eslint-disable-next-line no-bitwise -- base32 accumulator
    buffer = (buffer << 8) | byte;
    bitsInBuffer += 8;
    while (bitsInBuffer >= 5) {
      bitsInBuffer -= 5;
      // eslint-disable-next-line no-bitwise -- base32 accumulator
      const index = (buffer >> bitsInBuffer) & 0x1f;
      const char = alphabet[index];
      if (char === undefined) {
        throw new Error('unreachable: base32 index out of range');
      }
      out += char;
    }
  }
  if (out.length < MIN_PAIRING_CODE_LENGTH) {
    throw new Error('unreachable: generated pairing code below minimum length');
  }
  return out;
};

/**
 * `POST /api/v1/devices/:slug/pairing-code`
 *
 * The device calls this on every QR-refresh. Server mints a fresh
 * 160-bit opaque code, inserts a `device_pairing_code` row with
 * `code_hash` + the device's Tailscale endpoint, returns the
 * plaintext code to the device (and only the device). The device
 * renders it into the QR shown to the user.
 */
const pairingCodeHandler: DeviceRouteHandler = async (_request, identity) => {
  const code = generatePairingCode();
  const expiresAt = new Date(Date.now() + DEVICE_PAIRING_CODE_TTL_SECONDS * 1000);
  await issuePairingCode({
    code,
    deviceId: identity.slug,
    tailscaleHost: identity.tailscaleHost,
    tailscalePort: identity.tailscalePort,
    ...(identity.deviceName === null ? {} : { deviceName: identity.deviceName }),
    expiresAt,
  });
  return successResponse({
    code,
    device_id: identity.slug,
    expires_at: expiresAt.toISOString(),
  });
};

/**
 * `GET /api/v1/devices/:slug/acl`
 *
 * The device's ACL poller calls this every ~60 s. Server returns
 * the current active user SPKIs, plus a monotonic revision. The
 * poller updates its in-memory authorization set; any inbound TCP
 * `AuthRequest` whose user SPKI is not in the set is disconnected.
 */
const aclHandler: DeviceRouteHandler = async (_request, identity) => {
  const acl = await readDeviceAcl(identity.slug);
  return successResponse({
    device_id: acl.deviceSlug,
    revision: acl.revision,
    grants: acl.grants.map((g) => ({
      user_spki_b64: g.userSpkiB64,
      revision: g.revision,
      granted_at: g.grantedAt.toISOString(),
    })),
  });
};

const pairingCodeMethodRouter = (
  handler: (request: Request) => Promise<Response>,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') {
      const response = errorResponse(
        'method_not_allowed',
        `Method ${request.method} is not allowed on this resource`,
        405,
      );
      response.headers.set('Allow', 'POST');
      return response;
    }
    return await handler(request);
  };
};

const aclMethodRouter = (
  handler: (request: Request) => Promise<Response>,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'GET') {
      const response = errorResponse(
        'method_not_allowed',
        `Method ${request.method} is not allowed on this resource`,
        405,
      );
      response.headers.set('Allow', 'GET');
      return response;
    }
    return await handler(request);
  };
};

export const buildDevicesPairingCodeRoute = (
  options: RequireDeviceAttestedOptions = {},
): ((request: Request) => Promise<Response>) =>
  pairingCodeMethodRouter(withDeviceAttestation(pairingCodeHandler, options));

export const buildDevicesAclRoute = (
  options: RequireDeviceAttestedOptions = {},
): ((request: Request) => Promise<Response>) =>
  aclMethodRouter(withDeviceAttestation(aclHandler, options));

export const devicesPairingCodeRoute = buildDevicesPairingCodeRoute();
export const devicesAclRoute = buildDevicesAclRoute();

/**
 * Parse `/api/v1/devices/<slug>/<suffix>` and return the slug if the
 * pathname matches. Used by the top-level dispatch to pick between
 * the pairing-code and ACL routes without a full URL router.
 */
export interface DynamicDeviceRouteMatch {
  readonly slug: string;
  readonly kind: 'pairing-code' | 'acl';
}

export const matchDynamicDeviceRoute = (pathname: string): DynamicDeviceRouteMatch | null => {
  if (!pathname.startsWith(DEVICES_PAIRING_CODE_PATH_PREFIX)) {
    return null;
  }
  const remainder = pathname.slice(DEVICES_PAIRING_CODE_PATH_PREFIX.length);
  if (remainder.endsWith(DEVICES_PAIRING_CODE_PATH_SUFFIX)) {
    const slug = remainder.slice(0, -DEVICES_PAIRING_CODE_PATH_SUFFIX.length);
    if (slug.length === 0 || slug.includes('/')) {
      return null;
    }
    return { slug, kind: 'pairing-code' };
  }
  if (remainder.endsWith(DEVICES_ACL_PATH_SUFFIX)) {
    const slug = remainder.slice(0, -DEVICES_ACL_PATH_SUFFIX.length);
    if (slug.length === 0 || slug.includes('/')) {
      return null;
    }
    return { slug, kind: 'acl' };
  }
  return null;
};
