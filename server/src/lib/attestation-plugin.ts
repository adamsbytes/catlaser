import { timingSafeEqual } from 'node:crypto';
import { APIError, createAuthMiddleware } from 'better-auth/api';
import type { BetterAuthPlugin } from 'better-auth/types';
import type { AttestationBindingTag } from '~/lib/attestation-binding.ts';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import {
  AttestationSkewError,
  defaultNowSeconds,
  enforceTimestampSkew,
} from '~/lib/attestation-skew.ts';
import { AttestationVerifyError, verifyAttestationSignature } from '~/lib/attestation-verify.ts';
import {
  deleteMagicLinkAttestation,
  deriveTokenIdentifier,
  lookupMagicLinkAttestation,
} from '~/lib/magic-link-attestation.ts';
import { storeSessionAttestation } from '~/lib/session-attestation.ts';

/**
 * Device-attestation plugin.
 *
 * Gates every attestation-carrying auth endpoint with the v4 wire
 * contract described in ADR-006:
 *
 * - `POST /sign-in/magic-link`   — binding tag `req:<unix_seconds>`,
 *                                  ±60s skew enforced.
 * - `GET  /magic-link/verify`    — binding tag `ver:<magic_link_token>`,
 *                                  stored-fph + stored-pk byte-equal
 *                                  against the row captured at request
 *                                  time (DEVICE_MISMATCH on miss). On
 *                                  success, the `(fph, pk)` is copied
 *                                  into the freshly-minted session's
 *                                  `session_attestation` row so every
 *                                  protected `api:` call that follows
 *                                  verifies under that exact key, and
 *                                  the consumed `magic_link_attestation`
 *                                  row is deleted so the per-token
 *                                  binding cannot outlive its purpose.
 * - `POST /sign-in/social`       — binding tag
 *                                  `sis:<unix_seconds>:<raw_nonce>`,
 *                                  ±60s skew enforced, plus a three-way
 *                                  match between the binding's raw
 *                                  nonce, the request body's
 *                                  `idToken.nonce`, and the provider's
 *                                  own ID-token `nonce` claim (the
 *                                  third leg is enforced by the Apple /
 *                                  Google verifier configuration). The
 *                                  timestamp pins the replay window to
 *                                  ±60s — a captured `(body,
 *                                  attestation)` pair cannot be
 *                                  resubmitted once the window elapses,
 *                                  which closes the capture-then-replay
 *                                  vector the v3 nonce-only binding
 *                                  left open (the ID token's `exp`
 *                                  alone was ~10 minutes wide for Apple
 *                                  and up to an hour for Google). On
 *                                  success, the attestation pk is
 *                                  captured against the new session in
 *                                  `session_attestation`, same as the
 *                                  magic-link path.
 * - `POST /sign-out`             — binding tag `out:<unix_seconds>`,
 *                                  ±60s skew enforced.
 *
 * Request pipeline, in order of increasing cost and decreasing trust
 * distance:
 *
 * 1. Parse the `x-device-attestation` header (`ATTESTATION_REQUIRED` /
 *    `ATTESTATION_INVALID`).
 * 2. Assert the SPKI is a well-formed P-256 SubjectPublicKeyInfo
 *    (`ATTESTATION_SPKI_INVALID`).
 * 3. Assert the binding tag matches the endpoint
 *    (`ATTESTATION_BINDING_MISMATCH`).
 * 4. Verify the ECDSA signature over `fph_raw || bnd_utf8`
 *    (`ATTESTATION_SIGNATURE_INVALID`).
 * 5. For `/sign-in/social` only: the `sis:` nonce must byte-equal
 *    `body.idToken.nonce` (`ATTESTATION_NONCE_MISMATCH` /
 *    `ID_TOKEN_NONCE_REQUIRED`).
 * 6. For timestamped bindings (`req:`, `sis:`, `out:`, and `api:` on
 *    protected routes): enforce ±60s skew against the server clock
 *    (`ATTESTATION_SKEW_EXCEEDED`).
 * 7. For `ver:` only: look up the `(fph, pk)` captured at
 *    `/sign-in/magic-link` time under the same token identifier, and
 *    byte-compare against the verify-time attestation (`DEVICE_MISMATCH`
 *    on missing / stale row or on either of the two byte-compares).
 *
 * After a session-minting endpoint (`/magic-link/verify`,
 * `/sign-in/social`) completes successfully, an after-hook copies the
 * incoming attestation's `(fingerprintHash, publicKeySPKI)` into
 * `session_attestation` keyed on `ctx.context.newSession.session.id`.
 * This pins the session to a specific Secure-Enclave key; the
 * protected-route middleware in `protected-route.ts` verifies every
 * `api:` binding under that stored pk, collapsing "captured bearer"
 * into "captured bearer AND the non-extractable SE key" — the latter
 * is not a real threat. `Idempotency-Key` replay protection on
 * mutating routes lives on its own gate in `idempotency.ts` and does
 * not rewrite anything this plugin does.
 */

/**
 * HTTP header the iOS (and eventually Android) client attaches on every
 * authenticated call. Lowercased for canonical matching; `Headers.get`
 * is case-insensitive regardless.
 */
export const ATTESTATION_HEADER_NAME = 'x-device-attestation';

export type AttestationGateCode =
  | 'ATTESTATION_REQUIRED'
  | 'ATTESTATION_INVALID'
  | 'ATTESTATION_SPKI_INVALID'
  | 'ATTESTATION_BINDING_MISMATCH'
  | 'ATTESTATION_SIGNATURE_INVALID'
  | 'ATTESTATION_NONCE_MISMATCH'
  | 'ID_TOKEN_NONCE_REQUIRED'
  | 'ATTESTATION_SKEW_EXCEEDED'
  | 'DEVICE_MISMATCH';

/**
 * Per-path invariants: which binding tag is expected, whether the path
 * also requires the social-provider three-way nonce match, whether the
 * timestamp skew window applies, and whether the stored-fph/pk match
 * applies. Kept as a `Map` with exact string keys so a typo in an
 * endpoint path triggers a compile error at the call site rather than
 * silently skipping the attestation gate.
 */
interface PathSpec {
  readonly expectedTag: AttestationBindingTag;
  readonly requiresBodyNonceMatch: boolean;
  readonly enforcesSkew: boolean;
  readonly enforcesStoredDeviceMatch: boolean;
}

const PATH_SPECS: ReadonlyMap<string, PathSpec> = new Map<string, PathSpec>([
  [
    '/sign-in/magic-link',
    {
      expectedTag: 'request',
      requiresBodyNonceMatch: false,
      enforcesSkew: true,
      enforcesStoredDeviceMatch: false,
    },
  ],
  [
    '/magic-link/verify',
    {
      expectedTag: 'verify',
      requiresBodyNonceMatch: false,
      enforcesSkew: false,
      enforcesStoredDeviceMatch: true,
    },
  ],
  [
    '/sign-in/social',
    {
      expectedTag: 'social',
      requiresBodyNonceMatch: true,
      enforcesSkew: true,
      enforcesStoredDeviceMatch: false,
    },
  ],
  [
    '/sign-out',
    {
      expectedTag: 'signOut',
      requiresBodyNonceMatch: false,
      enforcesSkew: true,
      enforcesStoredDeviceMatch: false,
    },
  ],
]);

const attestationError = (
  status: 'UNAUTHORIZED' | 'BAD_REQUEST',
  code: AttestationGateCode,
  message: string,
): APIError =>
  new APIError(status, {
    code,
    message,
  });

const parseHeaderOrThrow = (headers: Headers | undefined): ParsedAttestation => {
  const headerValue = headers?.get(ATTESTATION_HEADER_NAME)?.trim();
  if (headerValue === undefined || headerValue.length === 0) {
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_REQUIRED',
      `missing or empty ${ATTESTATION_HEADER_NAME} header`,
    );
  }
  try {
    return decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw attestationError('UNAUTHORIZED', 'ATTESTATION_INVALID', error.message);
    }
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_INVALID',
      error instanceof Error ? error.message : 'attestation header parse failed',
    );
  }
};

const enforceSpkiAndSignature = (parsed: ParsedAttestation): void => {
  try {
    verifyAttestationSignature(parsed);
  } catch (error) {
    if (error instanceof AttestationVerifyError) {
      throw attestationError('UNAUTHORIZED', error.code, error.message);
    }
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_SIGNATURE_INVALID',
      error instanceof Error ? error.message : 'attestation verify threw',
    );
  }
};

const assertBindingTag = (parsed: ParsedAttestation, expected: AttestationBindingTag): void => {
  if (parsed.binding.tag !== expected) {
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_BINDING_MISMATCH',
      `expected '${expected}' binding, got '${parsed.binding.tag}'`,
    );
  }
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const extractIdTokenNonce = (body: unknown): string | undefined => {
  if (!isRecord(body)) {
    return undefined;
  }
  const idTokenCandidate = body['idToken'];
  if (!isRecord(idTokenCandidate)) {
    return undefined;
  }
  const { nonce } = idTokenCandidate;
  if (typeof nonce !== 'string' || nonce.length === 0) {
    return undefined;
  }
  return nonce;
};

const constantTimeStringEquals = (a: string, b: string): boolean => {
  const aBytes = Buffer.from(a, 'utf8');
  const bBytes = Buffer.from(b, 'utf8');
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

const assertBodyNonceMatches = (parsed: ParsedAttestation, body: unknown): void => {
  if (parsed.binding.tag !== 'social') {
    // Unreachable: callers only invoke this after `assertBindingTag(_, 'social')`.
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_BINDING_MISMATCH',
      'body-nonce match requires a social binding',
    );
  }
  const bodyNonce = extractIdTokenNonce(body);
  if (bodyNonce === undefined) {
    throw attestationError(
      'UNAUTHORIZED',
      'ID_TOKEN_NONCE_REQUIRED',
      'body.idToken.nonce is required for /sign-in/social',
    );
  }
  if (!constantTimeStringEquals(parsed.binding.rawNonce, bodyNonce)) {
    throw attestationError(
      'UNAUTHORIZED',
      'ATTESTATION_NONCE_MISMATCH',
      "attestation 'sis:' binding does not match body.idToken.nonce",
    );
  }
};

/**
 * Resolve the signed timestamp carried by a timestamped binding. All
 * bindings except `ver:` carry a timestamp — `req:`, `sis:`, `out:`,
 * and `api:` each sign a wall-clock second into their `bnd` so the
 * server can enforce the ±60s skew window. `ver:` binds to the
 * server-issued magic-link token (itself single-use and 5-minute
 * expiring), which plays the same freshness role without needing a
 * client-signed timestamp. Returns `undefined` for `ver:` so callers
 * can treat "this binding cannot be skew-checked" as a no-op without a
 * type cast.
 */
const bindingTimestamp = (parsed: ParsedAttestation): bigint | undefined => {
  const { binding } = parsed;
  switch (binding.tag) {
    case 'request':
    case 'social':
    case 'signOut':
    case 'api':
    case 'deleteAccount':
      return binding.timestamp;
    case 'verify':
      return undefined;
    default: {
      const exhaustive: never = binding;
      throw new Error(`unreachable AttestationBinding tag: ${JSON.stringify(exhaustive)}`);
    }
  }
};

const enforceSkewOrThrow = (parsed: ParsedAttestation, nowSeconds: NowSecondsFn): void => {
  const timestamp = bindingTimestamp(parsed);
  if (timestamp === undefined) {
    // A non-timestamped binding reaching a path that asks for skew
    // enforcement would be a compile-time wiring error; the
    // binding-tag check above rejects the request before this branch
    // can run, so this is a defensive no-op.
    return;
  }
  try {
    enforceTimestampSkew(timestamp, nowSeconds());
  } catch (error) {
    if (error instanceof AttestationSkewError) {
      throw attestationError('UNAUTHORIZED', 'ATTESTATION_SKEW_EXCEEDED', error.message);
    }
    throw error;
  }
};

const deviceMismatch = (message: string): APIError =>
  attestationError('UNAUTHORIZED', 'DEVICE_MISMATCH', message);

const utf8 = new TextEncoder();

/**
 * Byte-equal comparison of two base64(-url) strings in constant time. The
 * shared helper over UTF-8 bytes keeps the comparison constant-time under
 * the same contract `timingSafeEqual` provides for the sibling magic-link
 * callback-URL check.
 */
const timingSafeStringEquals = (a: string, b: string): boolean => {
  const aBytes = utf8.encode(a);
  const bBytes = utf8.encode(b);
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

const encodeStandardBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');

const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeStandardBase64(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

/**
 * For `ver:` bindings: load the stored attestation captured at request
 * time and byte-compare both the 32-byte fingerprint hash and the 91-byte
 * SPKI against the verify-time attestation. `DEVICE_MISMATCH` on any
 * miss — the row not existing, the fph differing, or the pk differing.
 *
 * The pk comparison is the load-bearing check against an attacker who
 * captured the emailed magic-link URL (email relay, shared mailbox, a
 * laptop that held the browser session). Such an attacker could forge a
 * `ver:<token>` attestation under their own Secure Enclave key and
 * satisfy the earlier ECDSA verify — which accepts whatever pk arrives
 * on the wire. Pinning the verify-time pk to the stored request-time pk
 * collapses that replay into a rejection before the magic-link plugin
 * consumes its verification row.
 */
const enforceStoredDeviceMatchOrThrow = async (parsed: ParsedAttestation): Promise<void> => {
  if (parsed.binding.tag !== 'verify') {
    // Unreachable when PATH_SPECS is configured correctly; the binding
    // tag check above rejects everything else.
    throw deviceMismatch('stored device match requires a verify binding');
  }
  const tokenIdentifier = deriveTokenIdentifier(parsed.binding.token);
  const stored = await lookupMagicLinkAttestation(tokenIdentifier);
  if (stored === null) {
    throw deviceMismatch(
      'no stored attestation for this magic-link token (expired, already consumed, or never issued on this device)',
    );
  }
  const wireFphB64Url = encodeBase64UrlNoPad(parsed.fingerprintHash);
  const wirePkB64 = encodeStandardBase64(parsed.publicKeySPKI);
  if (!timingSafeStringEquals(stored.fingerprintHashB64Url, wireFphB64Url)) {
    throw deviceMismatch(
      'verify-time fingerprint hash does not match the hash captured at request time',
    );
  }
  if (!timingSafeStringEquals(stored.publicKeySpkiB64, wirePkB64)) {
    throw deviceMismatch(
      'verify-time public key does not match the public key captured at request time',
    );
  }
};

const runAttestationGate = async (
  spec: PathSpec,
  ctx: { readonly headers: Headers | undefined; readonly body: unknown },
  nowSeconds: NowSecondsFn,
): Promise<void> => {
  const parsed = parseHeaderOrThrow(ctx.headers);
  assertBindingTag(parsed, spec.expectedTag);
  enforceSpkiAndSignature(parsed);
  if (spec.requiresBodyNonceMatch) {
    assertBodyNonceMatches(parsed, ctx.body);
  }
  if (spec.enforcesSkew) {
    enforceSkewOrThrow(parsed, nowSeconds);
  }
  if (spec.enforcesStoredDeviceMatch) {
    await enforceStoredDeviceMatchOrThrow(parsed);
  }
};

/**
 * Paths on which a successful response mints a new session. The
 * after-hook persists the captured attestation against
 * `ctx.context.newSession.session.id` so the protected-route middleware
 * has a stored pk to verify against on every subsequent `api:` call.
 *
 * `/sign-out` also carries an attestation binding but does not create a
 * session; explicitly excluded from the capture set.
 */
const SESSION_CAPTURE_PATHS: ReadonlySet<string> = new Set([
  '/magic-link/verify',
  '/sign-in/social',
]);

/**
 * Persist the captured `(fph, pk)` against the session id the
 * sign-in endpoint just produced. Runs only when:
 *
 * 1. The path is one the plugin's before-hook already gated (so the
 *    header is present and structurally sound).
 * 2. `ctx.context.newSession` is set — better-auth's `setSessionCookie`
 *    populates this on every successful session mint, so its absence
 *    means the endpoint short-circuited (e.g. redirect-only OAuth flow)
 *    and there is no session to bind to yet.
 *
 * Re-parsing the header here is cheap and deliberate — the before-hook
 * validated it but did not hand the parsed object down. A re-parse
 * failure at this stage would mean the hook pipeline regressed (the
 * before-hook accepted a payload it should have rejected, or the header
 * mutated between hooks); that is an invariant violation the server
 * must refuse the sign-in over rather than silently skip. Missing
 * attestation rows would 401 every protected call afterwards, which is
 * a worse failure mode than an explicit 500 here.
 */
/**
 * Re-parse the attestation header inside the after-hook. The before-hook
 * already validated it but does not pass the parsed object down; a
 * re-parse here is cheap. A re-parse failure at this stage would mean
 * the hook pipeline regressed (the before-hook accepted a payload it
 * should have rejected, or the header mutated between hooks); that is
 * an invariant violation the server must refuse the sign-in over rather
 * than silently skip. Missing attestation rows would 401 every
 * protected call afterwards, which is a worse failure mode than an
 * explicit 500 here.
 */
const reparseHeaderOrThrow = (path: string, headerValue: string): ParsedAttestation => {
  try {
    return decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw new Error(
        `${path} re-parse of '${ATTESTATION_HEADER_NAME}' failed (${error.code}: ${error.message}) — the before-hook should have rejected this upstream`,
        { cause: error },
      );
    }
    throw error;
  }
};

/**
 * Delete the `magic_link_attestation` row that backed a just-completed
 * verify. The stored `(fph, pk)` has done its job: the session was
 * minted, `session_attestation` now holds the per-session SE pubkey,
 * and the verification row itself was consumed by the magic-link plugin
 * (`allowedAttempts: 1`). Dropping the per-token row as soon as the
 * sign-in completes prevents a future plugin regression from relying on
 * stored fph/pk as a fallback gate and bounds the row's lifetime to the
 * actually-useful window rather than the natural 5-minute TTL.
 *
 * Best-effort: a delete failure here does not undo the successful
 * verify — the row expires naturally within the token lifetime and the
 * plugin's `allowedAttempts: 1` already blocks replay — so storage
 * errors are swallowed. Propagating would surface as 500 to the client
 * even though the sign-in has already completed server-side, leaving
 * the user in a worse state than a stale row.
 */
const purgeConsumedMagicLinkAttestation = async (parsed: ParsedAttestation): Promise<void> => {
  if (parsed.binding.tag !== 'verify') {
    // Unreachable on the verify path; defensive typing so the switch
    // stays narrow here.
    return;
  }
  try {
    await deleteMagicLinkAttestation(deriveTokenIdentifier(parsed.binding.token));
  } catch {
    // Swallow: see contract comment above.
  }
};

const captureSessionAttestation = async (
  path: string,
  headers: Headers | undefined,
  newSession: { readonly session: { readonly id: string } } | null | undefined,
): Promise<void> => {
  if (!SESSION_CAPTURE_PATHS.has(path)) {
    return;
  }
  if (newSession === null || newSession === undefined) {
    return;
  }
  const headerValue = headers?.get(ATTESTATION_HEADER_NAME) ?? undefined;
  if (headerValue === undefined) {
    throw new Error(
      `${path} reached the attestation after-hook without an '${ATTESTATION_HEADER_NAME}' header — the before-hook should have rejected this request`,
    );
  }
  const parsed = reparseHeaderOrThrow(path, headerValue);
  await storeSessionAttestation({
    sessionId: newSession.session.id,
    fingerprintHash: parsed.fingerprintHash,
    publicKeySPKI: parsed.publicKeySPKI,
  });
  if (path === '/magic-link/verify') {
    await purgeConsumedMagicLinkAttestation(parsed);
  }
};

/**
 * Factory options. A tests-only `nowSeconds` injection seam lets
 * integration tests drive the clock deterministically against fixed
 * attestation timestamps without monkey-patching `Date.now`. Production
 * callers omit the field and get `defaultNowSeconds` via the wall clock.
 */
export interface DeviceAttestationPluginOptions {
  readonly nowSeconds?: NowSecondsFn;
}

/**
 * Construct the device-attestation plugin. Exposed as a factory so the
 * id-stable plugin instance is created fresh per `createAuth()` call —
 * tests that spin up multiple auth instances must not share hook
 * closures.
 *
 * The only runtime configuration is the `nowSeconds` seam described on
 * `DeviceAttestationPluginOptions`. Every other invariant is pinned to
 * the wire contract, the SPKI structure, and the stored magic-link
 * attestation table.
 */
export const deviceAttestationPlugin = (
  options: DeviceAttestationPluginOptions = {},
): BetterAuthPlugin => {
  const nowSeconds = options.nowSeconds ?? defaultNowSeconds;
  return {
    id: 'device-attestation',
    hooks: {
      before: [
        {
          matcher: (context) => {
            const { path } = context;
            return typeof path === 'string' && PATH_SPECS.has(path);
          },
          handler: createAuthMiddleware(async (ctx) => {
            const { path, headers } = ctx;
            if (typeof path !== 'string') {
              return;
            }
            const spec = PATH_SPECS.get(path);
            if (spec === undefined) {
              return;
            }
            // `ctx.body` is typed `any` by better-auth; narrow to `unknown` at
            // the boundary so downstream helpers get a type-safe view.
            const body: unknown = ctx.body;
            await runAttestationGate(spec, { headers, body }, nowSeconds);
          }),
        },
      ],
      after: [
        {
          matcher: (context) => {
            const { path } = context;
            return typeof path === 'string' && SESSION_CAPTURE_PATHS.has(path);
          },
          handler: createAuthMiddleware(async (ctx) => {
            const { path, headers, context } = ctx;
            if (typeof path !== 'string') {
              return;
            }
            await captureSessionAttestation(path, headers, context.newSession);
          }),
        },
      ],
    },
  };
};
