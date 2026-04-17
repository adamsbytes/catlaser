import { timingSafeEqual } from 'node:crypto';
import { APIError, createAuthMiddleware } from 'better-auth/api';
import type { AuthMiddleware } from 'better-auth/api';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';

/** Header the client attaches on every authenticated call. Lowercased for
 *  canonical matching — `Headers.get` is case-insensitive regardless. */
export const ATTESTATION_HEADER_NAME = 'x-device-attestation';

export type SocialSignInAttestationCode =
  | 'ATTESTATION_REQUIRED'
  | 'ATTESTATION_INVALID'
  | 'ATTESTATION_BINDING_MISMATCH'
  | 'ATTESTATION_NONCE_MISMATCH'
  | 'ID_TOKEN_NONCE_REQUIRED';

const socialAttestationError = (code: SocialSignInAttestationCode, message: string): APIError =>
  new APIError('UNAUTHORIZED', {
    code,
    message,
  });

const constantTimeStringEquals = (a: string, b: string): boolean => {
  const aBytes = Buffer.from(a, 'utf8');
  const bBytes = Buffer.from(b, 'utf8');
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

const parseHeaderOrThrow = (headers: Headers | undefined): ParsedAttestation => {
  const headerValue = headers?.get(ATTESTATION_HEADER_NAME)?.trim();
  if (headerValue === undefined || headerValue.length === 0) {
    throw socialAttestationError(
      'ATTESTATION_REQUIRED',
      `missing or empty ${ATTESTATION_HEADER_NAME} header`,
    );
  }
  try {
    return decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw socialAttestationError('ATTESTATION_INVALID', error.message);
    }
    throw socialAttestationError(
      'ATTESTATION_INVALID',
      error instanceof Error ? error.message : 'attestation header parse failed',
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

/**
 * Guard `/sign-in/social` with the three-way nonce match described in
 * ADR-006 and BUILD.md Part 9 step 2:
 *
 * 1. `body.idToken.nonce` — the raw nonce the app pre-committed per sign-in.
 * 2. The ID-token `nonce` claim — matched by better-auth's provider-specific
 *    `verifyIdToken` (Google: verbatim; Apple: SHA-256 via the overridden
 *    verifier in `social-providers.ts`).
 * 3. The `bnd` field in the `x-device-attestation` header — must be
 *    `sis:<rawNonce>` and byte-equal to `body.idToken.nonce`.
 *
 * This hook owns points 1 + 3. Point 2 lives in the provider verify hook.
 * All three have to match for a sign-in to succeed.
 *
 * Failures always map to HTTP 401 with a distinct `code` per failure so the
 * client and server observability can tell them apart. The hook deliberately
 * does NOT short-circuit different failure modes into a single "something is
 * wrong" response — different failures carry different remediation.
 *
 * What this hook intentionally does NOT yet do (scope belongs to later
 * BUILD.md steps, not step 2):
 *
 * - Verify the ECDSA signature over `fph_raw || bnd_utf8` — step 5.
 * - Enforce the `sis:` / `req:` / `ver:` / `out:` skew windows — step 6.
 * - Persist the per-session SE public key — step 6/7.
 * - Apply the `api:` per-request attestation to protected routes — step 7.
 * - Enforce idempotency-key replay protection — step 8.
 *
 * All of those layer on top of the parse+match done here without re-doing
 * the wire-format work.
 */
// The middleware type contract requires an async function. The body is
// currently synchronous (parse + compare + throw) but will grow in step 5
// (ECDSA verify is async), so async is the long-lived signature here.
// eslint-disable-next-line @typescript-eslint/require-await
export const socialSignInAttestationHook: AuthMiddleware = createAuthMiddleware(async (ctx) => {
  if (ctx.path !== '/sign-in/social') {
    return;
  }

  const attestation = parseHeaderOrThrow(ctx.headers);

  if (attestation.binding.tag !== 'social') {
    throw socialAttestationError(
      'ATTESTATION_BINDING_MISMATCH',
      `expected 'sis:' binding for /sign-in/social, got '${attestation.binding.tag}'`,
    );
  }

  const bodyNonce = extractIdTokenNonce(ctx.body);
  if (bodyNonce === undefined) {
    throw socialAttestationError(
      'ID_TOKEN_NONCE_REQUIRED',
      'body.idToken.nonce is required for /sign-in/social',
    );
  }

  if (!constantTimeStringEquals(attestation.binding.rawNonce, bodyNonce)) {
    throw socialAttestationError(
      'ATTESTATION_NONCE_MISMATCH',
      "attestation 'sis:' binding does not match body.idToken.nonce",
    );
  }
});
