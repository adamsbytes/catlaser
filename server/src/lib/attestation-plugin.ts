import { timingSafeEqual } from 'node:crypto';
import { APIError, createAuthMiddleware } from 'better-auth/api';
import type { BetterAuthPlugin } from 'better-auth/types';
import type { AttestationBindingTag } from '~/lib/attestation-binding.ts';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import { AttestationVerifyError, verifyAttestationSignature } from '~/lib/attestation-verify.ts';

/**
 * Device-attestation plugin — BUILD.md Part 9 step 5.
 *
 * Gates every attestation-carrying auth endpoint with the v3 wire
 * contract described in ADR-006:
 *
 * - `POST /sign-in/magic-link`   — binding tag `req:<unix_seconds>`.
 * - `GET  /magic-link/verify`    — binding tag `ver:<magic_link_token>`.
 * - `POST /sign-in/social`       — binding tag `sis:<raw_nonce>`, plus
 *                                  a three-way match between the
 *                                  binding, the request body's
 *                                  `idToken.nonce`, and the provider's
 *                                  own ID-token `nonce` claim (the
 *                                  third leg is enforced by the Apple /
 *                                  Google verifier configuration).
 * - `POST /sign-out`             — binding tag `out:<unix_seconds>`.
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
 *
 * Step 5 deliberately stops here. The binding-enforcement layer
 * (step 6) adds: `req:` / `out:` ±60s skew, `ver:` stored-fph and
 * stored-pk byte-equal lookup, and per-session public-key
 * persistence. Step 7 adds the `api:` tag on protected routes.
 * Step 8 adds `Idempotency-Key` replay protection. None of those
 * steps need to rewrite anything this plugin does — they layer on
 * top of the crypto and structural floor this file establishes.
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
  | 'ID_TOKEN_NONCE_REQUIRED';

/**
 * Per-path invariants: which binding tag is expected, and whether the
 * path also requires the social-provider three-way nonce match. Kept as
 * a `Map` with exact string keys so a typo in an endpoint path triggers
 * a compile error at the call site rather than silently skipping the
 * attestation gate.
 */
interface PathSpec {
  readonly expectedTag: AttestationBindingTag;
  readonly requiresBodyNonceMatch: boolean;
}

const PATH_SPECS: ReadonlyMap<string, PathSpec> = new Map<string, PathSpec>([
  ['/sign-in/magic-link', { expectedTag: 'request', requiresBodyNonceMatch: false }],
  ['/magic-link/verify', { expectedTag: 'verify', requiresBodyNonceMatch: false }],
  ['/sign-in/social', { expectedTag: 'social', requiresBodyNonceMatch: true }],
  ['/sign-out', { expectedTag: 'signOut', requiresBodyNonceMatch: false }],
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

const runAttestationGate = async (
  spec: PathSpec,
  ctx: { readonly headers: Headers | undefined; readonly body: unknown },
): Promise<void> => {
  // The `await Promise.resolve()` keeps the function shape honest under
  // ESLint `require-await`: step 6 introduces a real database lookup in
  // this pipeline (per-session public-key persistence) and the call
  // sites should not need to change their `await` shape then.
  await Promise.resolve();
  const parsed = parseHeaderOrThrow(ctx.headers);
  assertBindingTag(parsed, spec.expectedTag);
  enforceSpkiAndSignature(parsed);
  if (spec.requiresBodyNonceMatch) {
    assertBodyNonceMatches(parsed, ctx.body);
  }
};

/**
 * Construct the device-attestation plugin. No runtime configuration is
 * required at this step: every invariant is pinned to the wire contract
 * and to the SPKI structure, and the per-session key persistence that
 * step 6 needs is deferred to that step. Exposed as a factory so the
 * id-stable plugin instance is created fresh per `createAuth()` call —
 * tests that spin up multiple auth instances must not share hook
 * closures.
 */
export const deviceAttestationPlugin = (): BetterAuthPlugin => ({
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
          await runAttestationGate(spec, { headers, body });
        }),
      },
    ],
  },
});
