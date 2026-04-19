import type { Auth } from 'better-auth';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import {
  AttestationSkewError,
  defaultNowSeconds,
  enforceTimestampSkew,
} from '~/lib/attestation-skew.ts';
import {
  AttestationVerifyError,
  verifyAttestationSignatureWithStoredKey,
} from '~/lib/attestation-verify.ts';
import { errorResponse } from '~/lib/http.ts';
import { lookupSessionAttestation } from '~/lib/session-attestation.ts';

/**
 * Protected-route attestation middleware — the enforcement half of the
 * "per-request attestation" decision in ADR-006.
 *
 * Sign-in binds the Secure-Enclave public key to the session row (the
 * attestation plugin's after-hook writes `session_attestation`). This
 * module is the other side of that contract: on every authenticated API
 * call, a fresh `api:<unix_seconds>` attestation signed by the same SE
 * key gates the request. A captured bearer alone is inert — without the
 * non-extractable private key the attacker cannot produce a signature
 * that verifies under the stored pk, regardless of what `fph` or `pk`
 * they send on the wire.
 *
 * The gate runs in order of increasing cost (a cheap structural check
 * short-circuits before the crypto verify) and decreasing trust distance
 * from the server (a known-bad bearer never touches the attestation
 * parse; a known-bad attestation shape never touches the signature
 * verify):
 *
 * 1. Resolve a session via `auth.api.getSession({ headers })`. On null,
 *    reject `401 SESSION_REQUIRED`.
 * 2. Read the `x-device-attestation` header. Missing or empty → reject
 *    `401 ATTESTATION_REQUIRED`.
 * 3. Decode the header. Structural failure → `401 ATTESTATION_INVALID`.
 * 4. Assert the binding tag is `api:`. Any other tag is either a
 *    misconfigured client or an attacker replaying a sign-in-time
 *    attestation — reject `401 ATTESTATION_BINDING_MISMATCH` either way.
 * 5. Load `session_attestation` by the session's id. Absent → reject
 *    `401 SESSION_ATTESTATION_MISSING`. In practice this row is written
 *    atomically inside the sign-in request so a missing row is either a
 *    schema regression or a session minted by a legacy flow; treating
 *    the absence as "skip the gate" would invert the security posture.
 * 6. Verify the ECDSA signature under the STORED SPKI, not the wire
 *    SPKI. This is the load-bearing invariant — the wire `pk` is
 *    ignored for verification. Failure → `401 ATTESTATION_SIGNATURE_INVALID`.
 *    The stored SPKI is still structurally validated for defence-in-depth
 *    by `verifyAttestationSignatureWithStoredKey`.
 * 7. Enforce the ±60s skew window against the server clock. Failure →
 *    `401 ATTESTATION_SKEW_EXCEEDED`. `Idempotency-Key` replay protection
 *    (in `idempotency.ts`) covers mutating routes; within the skew
 *    window, a read replay is non-harmful because it tells the attacker
 *    nothing new, and write replay is blocked by that sibling layer.
 *
 * Why not implement this as a better-auth plugin hook? Because
 * protected routes are not better-auth endpoints — they live outside
 * `AUTH_BASE_PATH`. The plugin hook lives on the auth router and would
 * never run here. Composing `requireAttestedSession` into the server's
 * own route dispatch keeps the enforcement visible at the call site: a
 * route that forgets to wrap itself in `withAttestedSession` will serve
 * unauthenticated traffic, which is a compile-reviewable failure mode.
 */

/** Every failure the gate can emit. Stable strings; clients switch on them. */
export type ProtectedRouteCode =
  | 'SESSION_REQUIRED'
  | 'SESSION_ATTESTATION_MISSING'
  | 'ATTESTATION_REQUIRED'
  | 'ATTESTATION_INVALID'
  | 'ATTESTATION_BINDING_MISMATCH'
  | 'ATTESTATION_SIGNATURE_INVALID'
  | 'ATTESTATION_SPKI_INVALID'
  | 'ATTESTATION_SKEW_EXCEEDED';

/**
 * Domain error raised by the gate. Carries the machine-readable code
 * the caller surfaces to the client in the JSON body. Every path that
 * rejects produces one of these — no bare `Error`s leak through.
 */
export class ProtectedRouteError extends Error {
  public readonly code: ProtectedRouteCode;
  public readonly status: number;

  public constructor(code: ProtectedRouteCode, message: string, status = 401) {
    super(message);
    this.name = 'ProtectedRouteError';
    this.code = code;
    this.status = status;
  }
}

/**
 * The exact shape of `ctx.context.newSession` that better-auth returns
 * from `auth.api.getSession({ headers })`. Reproducing only the fields
 * the middleware and downstream handlers rely on keeps the type surface
 * narrow — a future better-auth change that adds fields is forward-
 * compatible without an import churn.
 */
export interface AuthenticatedSession {
  readonly session: {
    readonly id: string;
    readonly userId: string;
    readonly expiresAt: Date;
    readonly token: string;
  };
  readonly user: {
    readonly id: string;
    readonly email: string;
    readonly emailVerified: boolean;
    readonly name: string;
  };
}

export interface RequireAttestedSessionOptions {
  readonly auth: Auth;
  readonly nowSeconds?: NowSecondsFn;
}

/**
 * Handler shape accepted by `withAttestedSession`. Receives the
 * original request plus the resolved session so handlers never re-
 * parse the bearer or the attestation.
 */
export type AttestedRouteHandler = (
  request: Request,
  session: AuthenticatedSession,
) => Response | Promise<Response>;

const parseAttestationHeaderOrThrow = (request: Request): ParsedAttestation => {
  const headerValue = request.headers.get(ATTESTATION_HEADER_NAME)?.trim();
  if (headerValue === undefined || headerValue.length === 0) {
    throw new ProtectedRouteError(
      'ATTESTATION_REQUIRED',
      `missing or empty ${ATTESTATION_HEADER_NAME} header`,
    );
  }
  try {
    return decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw new ProtectedRouteError('ATTESTATION_INVALID', error.message);
    }
    throw new ProtectedRouteError(
      'ATTESTATION_INVALID',
      error instanceof Error ? error.message : 'attestation header parse failed',
    );
  }
};

const assertApiBinding = (parsed: ParsedAttestation): bigint => {
  if (parsed.binding.tag !== 'api') {
    throw new ProtectedRouteError(
      'ATTESTATION_BINDING_MISMATCH',
      `expected 'api' binding on protected route, got '${parsed.binding.tag}'`,
    );
  }
  return parsed.binding.timestamp;
};

/**
 * Dedicated binding-tag check for the account-deletion route. A
 * captured `api:` attestation for a read-only call (e.g. GET /me)
 * must NOT satisfy the delete-account path within its 60s skew
 * window — the tag is the only structural separator between "I
 * authenticated an API call" and "I authenticated the permanent
 * destruction of this account." Every other difference (path, body,
 * verb) would be replayable. `del:` is the only accepted binding
 * here; everything else 401s with `ATTESTATION_BINDING_MISMATCH`.
 */
const assertDeleteAccountBinding = (parsed: ParsedAttestation): bigint => {
  if (parsed.binding.tag !== 'deleteAccount') {
    throw new ProtectedRouteError(
      'ATTESTATION_BINDING_MISMATCH',
      `expected 'deleteAccount' binding on delete-account route, got '${parsed.binding.tag}'`,
    );
  }
  return parsed.binding.timestamp;
};

const decodeStandardBase64 = (input: string): Uint8Array =>
  Uint8Array.from(Buffer.from(input, 'base64'));

const verifyStoredSignatureOrThrow = (parsed: ParsedAttestation, storedSpkiB64: string): void => {
  const storedSpki = decodeStandardBase64(storedSpkiB64);
  try {
    verifyAttestationSignatureWithStoredKey(parsed, storedSpki);
  } catch (error) {
    if (error instanceof AttestationVerifyError) {
      throw new ProtectedRouteError(error.code, error.message);
    }
    throw new ProtectedRouteError(
      'ATTESTATION_SIGNATURE_INVALID',
      error instanceof Error ? error.message : 'attestation verify threw',
    );
  }
};

const enforceSkewOrThrow = (timestamp: bigint, nowSeconds: NowSecondsFn): void => {
  try {
    enforceTimestampSkew(timestamp, nowSeconds());
  } catch (error) {
    if (error instanceof AttestationSkewError) {
      throw new ProtectedRouteError('ATTESTATION_SKEW_EXCEEDED', error.message);
    }
    throw error;
  }
};

/**
 * Resolve a bearer-authenticated session via better-auth. Returns the
 * strongly-typed `AuthenticatedSession` on success, throws
 * `ProtectedRouteError(SESSION_REQUIRED)` on miss.
 *
 * Uses `disableCookieCache: true` so a stale cookie-cache entry cannot
 * satisfy a request against a just-revoked session — protected routes
 * are the exact context where the sensitive-session invariant matters.
 */
const resolveSessionOrThrow = async (
  auth: Auth,
  request: Request,
): Promise<AuthenticatedSession> => {
  const resolved = await auth.api.getSession({
    headers: request.headers,
    query: { disableCookieCache: true },
  });
  if (resolved === null) {
    throw new ProtectedRouteError('SESSION_REQUIRED', 'no active session for this request');
  }
  return resolved as AuthenticatedSession;
};

const loadStoredAttestationOrThrow = async (
  sessionId: string,
): Promise<{ readonly publicKeySpkiB64: string; readonly fingerprintHashB64Url: string }> => {
  const stored = await lookupSessionAttestation(sessionId);
  if (stored === null) {
    throw new ProtectedRouteError(
      'SESSION_ATTESTATION_MISSING',
      'no attestation bound to this session (sign-in write regression)',
    );
  }
  return stored;
};

/**
 * Run the full protected-route gate against a request. Returns the
 * resolved session on success, throws `ProtectedRouteError` on any
 * gate failure.
 *
 * Callers that need to compose additional checks (e.g. the
 * `Idempotency-Key` guard in `idempotency.ts`) can wrap this function;
 * callers that just want "reject unless fully attested" should use
 * `withAttestedSession` instead.
 */
export const requireAttestedSession = async (
  request: Request,
  options: RequireAttestedSessionOptions,
): Promise<AuthenticatedSession> => {
  const nowSeconds = options.nowSeconds ?? defaultNowSeconds;
  const session = await resolveSessionOrThrow(options.auth, request);
  const parsed = parseAttestationHeaderOrThrow(request);
  const timestamp = assertApiBinding(parsed);
  const stored = await loadStoredAttestationOrThrow(session.session.id);
  verifyStoredSignatureOrThrow(parsed, stored.publicKeySpkiB64);
  enforceSkewOrThrow(timestamp, nowSeconds);
  return session;
};

/**
 * Variant of ``requireAttestedSession`` that requires a `del:`
 * binding tag. Used exclusively by the account-deletion route.
 *
 * Shares every other hop with ``requireAttestedSession`` — bearer
 * resolution, header parse, stored-SPKI signature verify, ±60s skew
 * enforcement — so the crypto floor is identical. The only
 * difference is the accepted binding tag: a captured `api:`
 * signature from any other authenticated call is refused here with
 * ``ATTESTATION_BINDING_MISMATCH``, closing the replay window that
 * a parameterless "any authenticated call" gate would otherwise
 * leave open against the most destructive operation the user can
 * perform through the app.
 */
export const requireDeleteAccountAttestedSession = async (
  request: Request,
  options: RequireAttestedSessionOptions,
): Promise<AuthenticatedSession> => {
  const nowSeconds = options.nowSeconds ?? defaultNowSeconds;
  const session = await resolveSessionOrThrow(options.auth, request);
  const parsed = parseAttestationHeaderOrThrow(request);
  const timestamp = assertDeleteAccountBinding(parsed);
  const stored = await loadStoredAttestationOrThrow(session.session.id);
  verifyStoredSignatureOrThrow(parsed, stored.publicKeySpkiB64);
  enforceSkewOrThrow(timestamp, nowSeconds);
  return session;
};

/**
 * Build a Response for a gate failure. The body mirrors `errorResponse`
 * so every protected-route rejection looks identical to the rest of the
 * server's error surface, and the machine-readable `code` matches the
 * strings documented in ADR-006.
 */
export const protectedRouteErrorResponse = (error: ProtectedRouteError): Response =>
  errorResponse(error.code, error.message, error.status);

/**
 * Higher-order wrapper that composes the gate onto a route handler.
 * Usage:
 *
 * ```ts
 * const meHandler: AttestedRouteHandler = (_, session) => successResponse({
 *   id: session.user.id, email: session.user.email,
 * });
 *
 * export const meRoute = withAttestedSession(meHandler, { auth });
 * ```
 *
 * Handlers see only well-formed requests from attested devices; every
 * rejection path produces a 401 with a machine-readable code. Callers
 * that need custom composition (idempotency-key dedupe, rate limiting)
 * should still start with `requireAttestedSession` so the gate ordering
 * stays consistent across the server.
 */
export const withAttestedSession = (
  handler: AttestedRouteHandler,
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    let session: AuthenticatedSession;
    try {
      session = await requireAttestedSession(request, options);
    } catch (error) {
      if (error instanceof ProtectedRouteError) {
        return protectedRouteErrorResponse(error);
      }
      throw error;
    }
    return await handler(request, session);
  };
};

/**
 * Higher-order wrapper that composes the delete-account gate onto a
 * route handler. Mirrors ``withAttestedSession`` except it requires
 * a `del:` binding tag.
 */
export const withDeleteAccountAttestedSession = (
  handler: AttestedRouteHandler,
  options: RequireAttestedSessionOptions,
): ((request: Request) => Promise<Response>) => {
  return async (request: Request): Promise<Response> => {
    let session: AuthenticatedSession;
    try {
      session = await requireDeleteAccountAttestedSession(request, options);
    } catch (error) {
      if (error instanceof ProtectedRouteError) {
        return protectedRouteErrorResponse(error);
      }
      throw error;
    }
    return await handler(request, session);
  };
};
