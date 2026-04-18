import { timingSafeEqual } from 'node:crypto';
import { APIError, createAuthMiddleware } from 'better-auth/api';
import type { AuthMiddleware } from 'better-auth/api';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import type { Env } from '~/lib/env.ts';
import { resolveAllowedCallbackUrl } from '~/lib/magic-link.ts';

/** Header the client attaches on every authenticated call. Lowercased for
 *  canonical matching — `Headers.get` is case-insensitive regardless. */
export const ATTESTATION_HEADER_NAME = 'x-device-attestation';

export type SocialSignInAttestationCode =
  | 'ATTESTATION_REQUIRED'
  | 'ATTESTATION_INVALID'
  | 'ATTESTATION_BINDING_MISMATCH'
  | 'ATTESTATION_NONCE_MISMATCH'
  | 'ID_TOKEN_NONCE_REQUIRED';

export type MagicLinkRequestHookCode = 'MAGIC_LINK_CALLBACK_FORBIDDEN';

const socialAttestationError = (code: SocialSignInAttestationCode, message: string): APIError =>
  new APIError('UNAUTHORIZED', {
    code,
    message,
  });

const magicLinkCallbackForbidden = (message: string): APIError =>
  new APIError('FORBIDDEN', {
    code: 'MAGIC_LINK_CALLBACK_FORBIDDEN' satisfies MagicLinkRequestHookCode,
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

const extractBodyCallbackURL = (body: unknown): string | undefined => {
  if (!isRecord(body)) {
    return undefined;
  }
  const { callbackURL } = body;
  if (typeof callbackURL !== 'string') {
    return undefined;
  }
  return callbackURL;
};

// The guards are declared `async` even though their bodies are currently
// synchronous: step 5 (ECDSA signature verification over `fph_raw ||
// bnd_utf8`) introduces real async work, and declaring the long-lived
// signature now means the call sites never have to move. The
// `await Promise.resolve()` at the top keeps the contract honest under
// ESLint `require-await` until the real await lands.
const runSocialSignInGuard = async (ctx: {
  readonly headers: Headers | undefined;
  readonly body: unknown;
}): Promise<void> => {
  await Promise.resolve();
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
};

const runMagicLinkRequestCallbackGuard = async (env: Env, body: unknown): Promise<void> => {
  await Promise.resolve();
  const submitted = extractBodyCallbackURL(body);
  if (submitted === undefined) {
    // Absent callbackURL → the `sendMagicLink` adapter builds the
    // Universal Link URL from env itself. Safe.
    return;
  }
  const allowed = resolveAllowedCallbackUrl(env);
  if (!constantTimeStringEquals(submitted, allowed)) {
    throw magicLinkCallbackForbidden(
      `callbackURL must exactly equal '${allowed}' (client-supplied hosts are rejected to block phishing-relay takeover)`,
    );
  }
};

/**
 * Build the single `hooks.before` middleware used by `createAuth`. The
 * better-auth options contract accepts only one before-middleware, so path-
 * matching and composition happen here.
 *
 * Paths currently guarded:
 *
 * - `POST /sign-in/social` — three-way nonce match between the request
 *   body's `idToken.nonce`, the `sis:<rawNonce>` attestation binding, and
 *   the provider-issued ID-token `nonce` claim (the third is enforced by
 *   the provider's `verifyIdToken` hook). Owned end-to-end by ADR-006 and
 *   BUILD.md Part 9 step 2. Failures map to HTTP 401 with a distinct
 *   `code` per failure.
 *
 * - `POST /sign-in/magic-link` — `callbackURL` allowlist enforcement.
 *   When a client submits `body.callbackURL`, it must byte-equal the
 *   configured Universal Link URL. Any other value — different host,
 *   different path, http scheme, relative path, trailing variation — is
 *   rejected with HTTP 403 `MAGIC_LINK_CALLBACK_FORBIDDEN`. The emailed
 *   URL itself is built server-side from env and never consumes the
 *   client-supplied value; this check is defence-in-depth against a
 *   future change that might.
 *
 * Not enforced here (by BUILD.md step boundaries):
 *
 * - ECDSA signature verification over `fph_raw || bnd_utf8` — step 5.
 * - `req:` / `ver:` / `sis:` / `out:` skew-window enforcement — step 6.
 * - Per-session SE public-key persistence — step 6/7.
 * - `api:` per-request attestation on protected routes — step 7.
 * - Idempotency-key replay protection — step 8.
 *
 * Every future step layers on top of the parse + match done here; none of
 * them rewrite it.
 */
export const buildBeforeHook = (env: Env): AuthMiddleware =>
  createAuthMiddleware(async (ctx) => {
    if (ctx.path === '/sign-in/social') {
      await runSocialSignInGuard(ctx);
    } else if (ctx.path === '/sign-in/magic-link') {
      await runMagicLinkRequestCallbackGuard(env, ctx.body);
    }
  });
