import { z } from 'zod';
import { auth } from '~/lib/auth.ts';
import {
  MAX_DEVICE_ID_LENGTH,
  MAX_PAIRING_CODE_LENGTH,
  exchangePairingCode,
  validateDeviceId,
  validatePairingCode,
} from '~/lib/device-pairing.ts';
import { errorResponse, successResponse } from '~/lib/http.ts';
import { withIdempotentAttestedSession } from '~/lib/idempotency.ts';
import type { IdempotentRouteHandler } from '~/lib/idempotency.ts';
import type { RequireAttestedSessionOptions } from '~/lib/protected-route.ts';

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
  });

  switch (outcome.kind) {
    case 'ok':
      return successResponse({
        device_id: outcome.device.deviceId,
        device_name: outcome.device.deviceName,
        host: outcome.device.host,
        port: outcome.device.port,
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

const ALLOWED_METHODS = ['POST'] as const;

const methodNotAllowed = (method: string): Response => {
  const response = errorResponse(
    'method_not_allowed',
    `Method ${method} is not allowed on ${DEVICES_PAIR_PATH}; accepted methods are ${ALLOWED_METHODS.join(', ')}.`,
    405,
  );
  response.headers.set('Allow', ALLOWED_METHODS.join(', '));
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
      return methodNotAllowed(request.method);
    }
    return await guardedPairHandler(request);
  };
};

export const devicesPairRoute = buildDevicesPairRoute({ auth });
