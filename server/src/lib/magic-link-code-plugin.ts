import { createHash } from 'node:crypto';
import { APIError, createAuthEndpoint } from 'better-auth/api';
import type { BetterAuthPlugin } from 'better-auth/types';
import { z } from 'zod';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { Env } from '~/lib/env.ts';
import { deleteMagicLinkAttestation } from '~/lib/magic-link-attestation.ts';
import {
  consumeMagicLinkCode,
  isPlausibleBackupCode,
  MAGIC_LINK_CODE_DIGITS,
} from '~/lib/magic-link-code.ts';

/**
 * Backup-code verify plugin. Registers `POST /magic-link/verify-by-code`
 * as a sibling to better-auth's built-in `GET /magic-link/verify`. Both
 * endpoints land on the same `verification` row; redeeming either makes
 * the other inert.
 *
 * Request flow — layered against the same invariants as the URL path:
 *
 *  1. The attestation plugin's `before` hook runs first (by path-match on
 *     `/magic-link/verify-by-code`) and validates the `x-device-attestation`
 *     header: v4 wire format, SPKI, `ver:<code>` binding, ECDSA signature
 *     over `fph || bnd`. A header rejection short-circuits before this
 *     handler ever runs.
 *
 *  2. This handler re-parses the header to get `(fph, pk)` — cheap and
 *     idempotent, required because the before-hook does not hand its
 *     parsed object down. It also asserts the attestation binding signs
 *     the same code the body submits; a divergence rejects as
 *     `ATTESTATION_BINDING_MISMATCH` (closes a theoretical captured-ver
 *     relay).
 *
 *  3. `consumeMagicLinkCode` atomically looks up the stored row by the
 *     submitted code's HMAC identifier, byte-matches the stored
 *     `(fph, pk)` against the wire attestation, and either deletes the
 *     row (match) or decrements the attempts counter (miss). A
 *     `not-found` outcome and a `mismatch` outcome both surface as 401.
 *
 *  4. On match, the stored plaintext token is hashed into the identifier
 *     better-auth's verification row uses (SHA-256 base64url-no-pad —
 *     byte-identical to the plugin's `defaultKeyHasher`). The normal
 *     magic-link session-mint path is then replayed directly against
 *     `ctx.context.internalAdapter` (see `completeSignIn`).
 *
 *  5. The `magic_link_attestation` row is also deleted so a future
 *     URL-verify on the already-minted session cannot redeem the
 *     sibling row and produce a second session.
 *
 *  6. The `session_attestation` row is written by the attestation plugin's
 *     after-hook, which runs for every path in `SESSION_CAPTURE_PATHS`
 *     (including this one).
 *
 * The response shape matches `GET /magic-link/verify`'s JSON body:
 * `{ token, user, session }`. The bearer plugin sets the
 * `set-auth-token` response header via `setSessionCookie`.
 */

const BODY_SCHEMA = z.strictObject({
  code: z
    .string()
    .min(MAGIC_LINK_CODE_DIGITS)
    .max(MAGIC_LINK_CODE_DIGITS + 4)
    .refine(isPlausibleBackupCode, 'code must be 6 digits'),
});

interface VerificationPayload {
  readonly email: string;
  readonly name?: string;
  readonly attempt: number;
}

const VERIFICATION_PAYLOAD_SHAPE = z.looseObject({
  email: z.string().min(1),
  name: z.string().optional(),
  attempt: z.number().optional(),
});

/**
 * Better-auth's `ctx.context.internalAdapter` type surface, narrowed to
 * just the methods this plugin calls. Declaring a local shape avoids a
 * deep dependency on private better-auth type names that shift between
 * minor releases — a drift in the upstream method signatures would
 * still surface at runtime (the adapter is typed `unknown` on the other
 * side of the assertion, so missing methods crash immediately), so we
 * keep the surface minimal and loud.
 */
interface MinimalInternalAdapter {
  findVerificationValue: (
    id: string,
  ) => Promise<{ value: string; expiresAt: Date } | null | undefined>;
  deleteVerificationByIdentifier: (id: string) => Promise<unknown>;
  findUserByEmail: (email: string) => Promise<{ user: MinimalUser } | null | undefined>;
  createUser: (input: {
    email: string;
    emailVerified: boolean;
    name: string;
  }) => Promise<MinimalUser>;
  updateUser: (id: string, input: Record<string, unknown>) => Promise<MinimalUser>;
  createSession: (userId: string) => Promise<MinimalSession | null | undefined>;
}

interface MinimalUser {
  readonly id: string;
  readonly emailVerified: boolean;
  readonly [key: string]: unknown;
}

interface MinimalSession {
  readonly id: string;
  readonly token: string;
  readonly [key: string]: unknown;
}

/**
 * Hash a plaintext magic-link token into the identifier better-auth's
 * verification row is keyed by. Byte-identical to
 * `magic-link/utils.mjs#defaultKeyHasher` so the two lookup paths see the
 * same identifier string.
 */
const hashTokenToIdentifier = (token: string): string =>
  createHash('sha256')
    .update(token, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

interface ReparsedHeader {
  readonly fingerprintHash: Uint8Array;
  readonly publicKeySPKI: Uint8Array;
  readonly bindingToken: string;
}

const reparseHeaderOrThrow = (headers: Headers | undefined): ReparsedHeader => {
  const headerValue = headers?.get(ATTESTATION_HEADER_NAME)?.trim();
  if (headerValue === undefined || headerValue.length === 0) {
    // Unreachable when the attestation plugin's before-hook is wired:
    // an empty header aborts with ATTESTATION_REQUIRED before the
    // endpoint fires. Throw so a regression surfaces instead of
    // silently letting the request through.
    throw new Error(
      `verify-by-code reached without an '${ATTESTATION_HEADER_NAME}' header — the attestation plugin should have rejected this request`,
    );
  }
  let parsed;
  try {
    parsed = decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw new Error(
        `verify-by-code re-parse of '${ATTESTATION_HEADER_NAME}' failed (${error.code}: ${error.message}) — the attestation plugin should have rejected this request upstream`,
        { cause: error },
      );
    }
    throw error;
  }
  if (parsed.binding.tag !== 'verify') {
    // Unreachable: the attestation-plugin before-hook already rejects
    // anything that isn't `verify` on this path.
    throw new APIError('UNAUTHORIZED', {
      code: 'ATTESTATION_BINDING_MISMATCH',
      message: "expected 'verify' binding",
    });
  }
  return {
    fingerprintHash: parsed.fingerprintHash,
    publicKeySPKI: parsed.publicKeySPKI,
    bindingToken: parsed.binding.token,
  };
};

const parseVerificationPayload = (value: string): VerificationPayload => {
  let decoded: unknown;
  try {
    decoded = JSON.parse(value);
  } catch {
    throw new APIError('INTERNAL_SERVER_ERROR', {
      code: 'INVALID_CODE',
      message: 'magic-link verification row is malformed',
    });
  }
  const parsed = VERIFICATION_PAYLOAD_SHAPE.safeParse(decoded);
  if (!parsed.success) {
    throw new APIError('INTERNAL_SERVER_ERROR', {
      code: 'INVALID_CODE',
      message: 'magic-link verification row is malformed',
    });
  }
  const { email, name, attempt } = parsed.data;
  if (name === undefined) {
    return { email, attempt: attempt ?? 0 };
  }
  return { email, name, attempt: attempt ?? 0 };
};

const invalidCode = (message: string): APIError =>
  new APIError('UNAUTHORIZED', { code: 'INVALID_CODE', message });

const deviceMismatch = (message: string): APIError =>
  new APIError('UNAUTHORIZED', { code: 'DEVICE_MISMATCH', message });

/**
 * Strip spaces and hyphens from a backup code so the attestation-binding
 * match is insensitive to cosmetic separators the body might carry.
 * Matches `magic-link-code.ts#normalizeCode`.
 */
const normalizeCodeDisplay = (code: string): string => code.replaceAll(/[\s\-]/gv, '');

/**
 * Consume the better-auth verification row and return the parsed
 * payload. Separated out of the endpoint handler so the sonarjs cognitive-
 * complexity ceiling stays clear on both sides of the boundary.
 *
 * Copies the URL-path logic (find, check expiry, check attempts, delete)
 * byte-for-byte so the two paths behave identically on expired / used
 * verification rows. The cleanup of the sibling `magic_link_attestation`
 * row happens here rather than in `completeSignIn` so a failure to
 * resolve the row still doesn't leak the attestation binding.
 */
const consumeVerificationRowOrThrow = async (
  adapter: MinimalInternalAdapter,
  tokenIdentifier: string,
): Promise<VerificationPayload> => {
  const tokenRow = await adapter.findVerificationValue(tokenIdentifier);
  if (tokenRow === null || tokenRow === undefined) {
    throw invalidCode('magic-link verification row is missing — request a fresh link');
  }
  if (tokenRow.expiresAt < new Date()) {
    await adapter.deleteVerificationByIdentifier(tokenIdentifier);
    throw invalidCode('magic-link has expired — request a fresh link');
  }
  const payload = parseVerificationPayload(tokenRow.value);
  if (payload.attempt >= 1) {
    // Mirrors the URL path's `allowedAttempts: 1` semantic.
    await adapter.deleteVerificationByIdentifier(tokenIdentifier);
    throw invalidCode('magic-link has already been used — request a fresh one');
  }
  await adapter.deleteVerificationByIdentifier(tokenIdentifier);
  try {
    await deleteMagicLinkAttestation(tokenIdentifier);
  } catch {
    // Best-effort: see magic-link-attestation.ts contract.
  }
  return payload;
};

/**
 * Resolve or create the user and mint a session. Extracted so the
 * endpoint handler stays inside the sonarjs cognitive-complexity
 * ceiling.
 */
const resolveUserAndMintSession = async (
  adapter: MinimalInternalAdapter,
  payload: VerificationPayload,
): Promise<{ user: MinimalUser; session: MinimalSession }> => {
  const existing = await adapter.findUserByEmail(payload.email);
  let user = existing?.user;
  if (user === undefined) {
    user = await adapter.createUser({
      email: payload.email,
      emailVerified: true,
      name: payload.name ?? '',
    });
  } else if (!user.emailVerified) {
    user = await adapter.updateUser(user.id, { emailVerified: true });
  }
  const session = await adapter.createSession(user.id);
  if (session === null || session === undefined) {
    throw new APIError('INTERNAL_SERVER_ERROR', {
      code: 'SESSION_CREATE_FAILED',
      message: 'could not create session for this magic-link verification',
    });
  }
  return { user, session };
};

/**
 * Dynamic import of `better-auth/cookies` keeps the plugin tree-shakable
 * and avoids a static import of a subpath that may not resolve under
 * every module-resolution config. The URL verify endpoint inside
 * better-auth uses the same subpath.
 *
 * The `ctx` parameter is typed as `unknown` + the call-site cast to the
 * dynamically-imported function's expected signature so the plugin
 * surface does not pull in `GenericEndpointContext` / `Session` / `User`
 * from `@better-auth/core`. Type drift in those names between minor
 * releases would otherwise break compilation here for no runtime
 * reason.
 */
const writeSessionCookie = async (
  ctx: unknown,
  user: MinimalUser,
  session: MinimalSession,
): Promise<void> => {
  const cookies = await import('better-auth/cookies');
  type SetSessionCookie = typeof cookies.setSessionCookie;
  // eslint-disable-next-line @typescript-eslint/no-unsafe-type-assertion
  const typed = cookies.setSessionCookie as unknown as (
    ctx: unknown,
    payload: { session: MinimalSession; user: MinimalUser },
  ) => ReturnType<SetSessionCookie>;
  await typed(ctx, { session, user });
};

export const buildMagicLinkCodePlugin = (env: Env): BetterAuthPlugin => {
  const secret = env.BETTER_AUTH_SECRET;
  return {
    id: 'magic-link-code',
    endpoints: {
      magicLinkVerifyByCode: createAuthEndpoint(
        '/magic-link/verify-by-code',
        {
          method: 'POST',
          body: BODY_SCHEMA,
          requireHeaders: true,
        },
        async (ctx) => {
          const { code } = ctx.body;
          const parsed = reparseHeaderOrThrow(ctx.headers);

          // Defence-in-depth: the attestation binding MUST sign the
          // same code the body submits. The iOS client always signs
          // `ver:<code>` under the SE key it used at request time — any
          // divergence here would mean a buggy client or a captured
          // `ver:<URL-token>` attestation being relayed to this endpoint.
          if (parsed.bindingToken !== normalizeCodeDisplay(code)) {
            throw new APIError('UNAUTHORIZED', {
              code: 'ATTESTATION_BINDING_MISMATCH',
              message: 'attestation binding does not sign the submitted code',
            });
          }

          const outcome = await consumeMagicLinkCode({
            code,
            secret,
            wireFingerprintHash: parsed.fingerprintHash,
            wirePublicKeySPKI: parsed.publicKeySPKI,
          });
          if (outcome.kind === 'not-found') {
            throw invalidCode(
              'backup code is invalid, already used, or expired — request a fresh magic link',
            );
          }
          if (outcome.kind === 'mismatch') {
            throw deviceMismatch(
              "this code wasn't requested on this device — open the email link on the phone that asked for it, or request a fresh code on this one",
            );
          }

          const tokenIdentifier = hashTokenToIdentifier(outcome.plaintextToken);
          // Safety belt: the row we just consumed stored its own
          // tokenIdentifier alongside the plaintext. A divergence
          // would mean our hash drifted from better-auth's; reject
          // loudly rather than mint against a wrong key.
          if (tokenIdentifier !== outcome.tokenIdentifier) {
            throw new Error(
              'hashTokenToIdentifier output does not match the stored token_identifier — defaultKeyHasher drift?',
            );
          }

          // The real internalAdapter exposes more methods than the
          // minimal surface this plugin needs; narrowing it here keeps
          // the plugin decoupled from better-auth's private typing,
          // which shifts between minor releases. The double `unknown`
          // is the prescribed escape hatch from the unsafe-type-
          // assertion rule when a principled narrowing is wanted.
          // eslint-disable-next-line @typescript-eslint/no-unsafe-type-assertion
          const adapter = ctx.context.internalAdapter as unknown as MinimalInternalAdapter;
          const payload = await consumeVerificationRowOrThrow(adapter, tokenIdentifier);
          const { user, session } = await resolveUserAndMintSession(adapter, payload);
          await writeSessionCookie(ctx, user, session);

          return await ctx.json({
            token: session.token,
            user,
            session,
          });
        },
      ),
    },
  };
};
