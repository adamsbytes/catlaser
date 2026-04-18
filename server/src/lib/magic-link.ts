import { magicLink } from 'better-auth/plugins';
import type { Logger } from 'pino';
import pino from 'pino';
import type { Env } from '~/lib/env.ts';

/**
 * Magic-link plugin wiring for better-auth.
 *
 * This module owns two invariants that together close the phishing-relay
 * takeover vector:
 *
 * 1. The URL embedded in outgoing emails is constructed deterministically
 *    from `MAGIC_LINK_UNIVERSAL_LINK_HOST` + `MAGIC_LINK_UNIVERSAL_LINK_PATH`
 *    — it is NOT derived from `ctx.body.callbackURL`. A client cannot
 *    influence the emailed link.
 *
 * 2. The `callbackURL` body field on `POST /sign-in/magic-link`, when
 *    present, is allowlisted in a before-hook to the exact Universal Link
 *    URL. Any other host, path, scheme, or relative-path value is rejected.
 *    This defends against a future bug that consumed `ctx.body.callbackURL`
 *    somewhere in the verify pipeline (e.g. as a redirect target after
 *    browser fallback) and guarantees the request's declared callback
 *    agrees with what will be emailed.
 *
 * The verify-side `callbackURL` query parameter is already allowlisted by
 * the plugin's built-in `originCheck` middleware against `trustedOrigins`
 * — see `/magic-link/verify` in the upstream plugin source.
 *
 * Attestation binding enforcement (the `ver:` / `req:` tags on the
 * attestation header) is explicitly deferred to Part 9 step 6; the social
 * `sis:` enforcement in `auth-hooks.ts` is unrelated to this plugin and
 * stays on its own path-matched hook.
 */

/** Default magic-link token lifetime. Mirrors the plugin's own default. */
export const MAGIC_LINK_EXPIRES_IN_SECONDS = 60 * 5;

/** Default per-path rate-limit window. */
export const MAGIC_LINK_RATE_LIMIT_WINDOW_SECONDS = 60;

/** Default max requests per window. */
export const MAGIC_LINK_RATE_LIMIT_MAX = 5;

/**
 * Payload handed to a `MagicLinkDelivery` implementation when a user
 * requests a magic link. `magicLink` is the fully-formed Universal Link
 * URL including the `?token=<token>` query — mail templates should render
 * it verbatim; composing a different URL from the raw `token` defeats the
 * phishing-relay defence.
 */
export interface MagicLinkEmailPayload {
  readonly email: string;
  readonly token: string;
  readonly magicLink: string;
}

/**
 * Delivery adapter interface. Production transports (SMTP, Resend, SES,
 * etc.) implement this; the default `pinoMagicLinkDelivery` logs instead
 * of sending, so that sign-in flows are observable in development without
 * requiring an outbound mail configuration.
 *
 * Implementations must throw on any delivery failure — better-auth
 * surfaces a thrown error as HTTP 500, which is the correct signal to the
 * client that no email was sent.
 */
export interface MagicLinkDelivery {
  readonly send: (payload: MagicLinkEmailPayload) => Promise<void>;
}

/**
 * Default delivery adapter. Logs at `info` in development / test and at
 * `warn` in production — a production deployment that hasn't wired a real
 * transport yet should surface loudly in ops dashboards rather than drop
 * mail silently. The token is redacted: the `magicLink` field carries the
 * same value and is what humans need; logging the bare token would give a
 * log scrape a usable credential.
 */
export const pinoMagicLinkDelivery = (env: Env, parentLogger?: Logger): MagicLinkDelivery => {
  const isDev = env.NODE_ENV !== 'production';
  const baseLogger =
    parentLogger ?? (isDev ? pino({ transport: { target: 'pino-pretty' } }) : pino());
  const logger = baseLogger.child({ module: 'magic-link' });
  return {
    send: async (payload) => {
      await Promise.resolve();
      const record = {
        email: payload.email,
        magicLink: payload.magicLink,
        tokenRedacted: true,
      };
      if (isDev) {
        logger.info(
          record,
          'magic-link delivery (dev stub) — copy the URL into a browser to sign in',
        );
      } else {
        logger.warn(
          record,
          'magic-link delivery (prod stub) — no transport configured, email was NOT sent',
        );
      }
    },
  };
};

/**
 * Build the absolute Universal Link URL that the emailed magic link points
 * at, with `token` attached. Used both as the authoritative emailed URL
 * and as the allowlist value against which client-supplied `callbackURL`
 * submissions are compared.
 *
 * URL construction uses the WHATWG `URL` API so percent-encoding is
 * applied consistently on both sides of the comparison.
 */
export const buildUniversalLinkURL = (env: Env, token?: string): URL => {
  const url = new URL(
    env.MAGIC_LINK_UNIVERSAL_LINK_PATH,
    `https://${env.MAGIC_LINK_UNIVERSAL_LINK_HOST}`,
  );
  if (typeof token === 'string') {
    url.searchParams.set('token', token);
  }
  return url;
};

/**
 * The canonical serialized form of the Universal Link URL, WITHOUT a
 * token. Clients should submit this (or nothing) as `callbackURL` on
 * `POST /sign-in/magic-link`. Any other value is rejected by the
 * allowlist hook.
 *
 * Exposed separately from `buildUniversalLinkURL` so that the env-derived
 * string can be memoized and compared byte-for-byte — comparing URL
 * objects would obscure trailing-slash and empty-query differences that
 * are otherwise useful allowlist-miss signals.
 */
export const resolveAllowedCallbackUrl = (env: Env): string =>
  buildUniversalLinkURL(env).toString();

/**
 * Returns the configured better-auth magic-link plugin. The caller owns
 * delivery wiring: a production deployment injects an SMTP/Resend/SES
 * adapter; tests inject a recorder so assertions can inspect exactly what
 * would have been emailed.
 */
export const buildMagicLinkPlugin = (
  env: Env,
  delivery: MagicLinkDelivery,
): ReturnType<typeof magicLink> =>
  magicLink({
    expiresIn: MAGIC_LINK_EXPIRES_IN_SECONDS,
    allowedAttempts: 1,
    // Tokens are stored under their SHA-256 digest so a database read
    // (backup leak, read replica compromise, DBA curiosity) cannot be
    // redeemed into a sign-in session. The plugin hashes on write and on
    // verify lookup, so the wire token (what's in the email) is still the
    // plaintext random value.
    storeToken: 'hashed',
    rateLimit: {
      window: MAGIC_LINK_RATE_LIMIT_WINDOW_SECONDS,
      max: MAGIC_LINK_RATE_LIMIT_MAX,
    },
    // The plugin-supplied `url` parameter points at the server's own
    // verify endpoint with `token` + `callbackURL` query params. We ignore
    // it entirely. The emailed URL MUST be the Universal Link, so that a
    // tap on the email opens the app (via AASA / assetlinks) rather than
    // Safari — and so that a client's `body.callbackURL` cannot influence
    // what the server emails.
    sendMagicLink: async ({ email, token }) => {
      const magicLinkURL = buildUniversalLinkURL(env, token).toString();
      await delivery.send({ email, token, magicLink: magicLinkURL });
    },
  });
