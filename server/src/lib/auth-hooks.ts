import { timingSafeEqual } from 'node:crypto';
import { APIError, createAuthMiddleware } from 'better-auth/api';
import type { AuthMiddleware } from 'better-auth/api';
import type { Env } from '~/lib/env.ts';
import { resolveAllowedCallbackUrl } from '~/lib/magic-link.ts';

/**
 * Top-level `options.hooks.before` wiring. All device-attestation
 * concerns — header parse, SPKI validation, per-tag binding match,
 * ECDSA verify, and the social-provider nonce three-way match — live
 * in `~/lib/attestation-plugin.ts` and run as a better-auth plugin
 * hook. What remains here is everything that is NOT attestation:
 * today that means exactly the magic-link callback-URL allowlist,
 * which is a property of the email we're about to send and has no
 * cryptographic surface.
 *
 * Ordering: better-auth executes `options.hooks.before` before plugin
 * `hooks.before` (see `toAuthEndpoints.getHooks`). The callback-URL
 * allowlist running first means a malformed `callbackURL` on a
 * `sign-in/magic-link` request is refused before any attestation
 * parse is attempted — useful for both privacy (the header might
 * encode identifying bytes) and latency (the request is bad either
 * way). Attestation failures still dominate the response code for
 * requests where the callback URL is absent or byte-equal to the
 * allowlist.
 */

export type MagicLinkRequestHookCode = 'MAGIC_LINK_CALLBACK_FORBIDDEN';

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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

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

const runMagicLinkRequestCallbackGuard = async (env: Env, body: unknown): Promise<void> => {
  // `async` shape is preserved for symmetry with other before-guard
  // helpers this file has historically carried; the body itself stays
  // synchronous today.
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
 * Build the single `hooks.before` middleware used by `createAuth`.
 *
 * Paths currently guarded:
 *
 * - `POST /sign-in/magic-link` — `callbackURL` allowlist enforcement.
 *   When a client submits `body.callbackURL`, it must byte-equal the
 *   configured Universal Link URL. Any other value — different host,
 *   different path, http scheme, relative path, trailing variation —
 *   is rejected with HTTP 403 `MAGIC_LINK_CALLBACK_FORBIDDEN`. The
 *   emailed URL itself is built server-side from env and never
 *   consumes the client-supplied value; this check is defence-in-
 *   depth against a future change that might.
 *
 * Every other step boundary — attestation parse / SPKI / binding /
 * ECDSA verify / nonce three-way / `req:` / `out:` skew / `ver:`
 * stored-fph + pk byte-equal / `api:` per-request / idempotency —
 * lives in the attestation plugin or in step 6+ additions to it, not
 * here. Adding a fifth concern to this file means adding a fifth
 * subsystem; adding attestation code here instead of in the plugin
 * would cross the trust boundary this split is designed to preserve.
 */
export const buildBeforeHook = (env: Env): AuthMiddleware =>
  createAuthMiddleware(async (ctx) => {
    if (ctx.path === '/sign-in/magic-link') {
      await runMagicLinkRequestCallbackGuard(env, ctx.body);
    }
  });
