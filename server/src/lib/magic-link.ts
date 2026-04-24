import { magicLink } from 'better-auth/plugins';
import type { Logger } from 'pino';
import pino from 'pino';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import { AttestationHeaderParseError, decodeAttestationHeader } from '~/lib/attestation-header.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { Env } from '~/lib/env.ts';
import { deriveTokenIdentifier, storeMagicLinkAttestation } from '~/lib/magic-link-attestation.ts';
import {
  generateBackupCode,
  MAGIC_LINK_CODE_EXPIRES_IN_SECONDS,
  storeMagicLinkCode,
} from '~/lib/magic-link-code.ts';

/**
 * Magic-link plugin wiring for better-auth.
 *
 * This module owns three invariants:
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
 * 3. The `(fph, pk)` attestation pair captured at request time is
 *    persisted against the magic-link token's identifier before the email
 *    goes out, so `GET /magic-link/verify` can byte-match the verify-time
 *    attestation against it. This closes the email-interception takeover
 *    vector: an attacker who grabs the emailed URL but does not own the
 *    original Secure Enclave key cannot produce a verify attestation that
 *    matches the stored pk.
 *
 * The verify-side `callbackURL` query parameter is already allowlisted by
 * the plugin's built-in `originCheck` middleware against `trustedOrigins`
 * — see `/magic-link/verify` in the upstream plugin source.
 *
 * The social `sis:` enforcement in `auth-hooks.ts` is unrelated to this
 * plugin and stays on its own path-matched hook. The ±60s skew contract
 * for `req:` / `out:` / `api:` lives in `attestation-plugin.ts` alongside
 * the rest of the attestation gate.
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
 * phishing-relay defence. `code` is the 6-digit backup code the user can
 * enter on the original device when reading email on a different one —
 * mail templates MUST render both or the cross-device sign-in path breaks.
 */
export interface MagicLinkEmailPayload {
  readonly email: string;
  readonly token: string;
  readonly magicLink: string;
  readonly code: string;
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
        // The backup code is surfaced in dev logs so a developer testing
        // the cross-device flow on the same laptop can redeem by code
        // without running a mail stub. In production the code lands in
        // the user's inbox alongside the URL; logging it would be a
        // credential-leak channel, so prod logs redact it. Both paths
        // redact the underlying token — it is never user-facing.
        code: isDev ? payload.code : undefined,
        tokenRedacted: true,
      };
      if (isDev) {
        logger.info(
          record,
          'magic-link delivery (dev stub) — copy the URL into a browser to sign in, or enter the code on the requesting device',
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
 * Re-parse the attestation header the attestation plugin's `before` hook
 * already validated. Idempotent and cheap; the plugin API does not pass
 * the parsed object down, so the header is the shared artefact between
 * layers.
 *
 * A missing or malformed header at this stage would mean the plugin
 * ordering silently changed or the attestation plugin regressed. Throwing
 * here keeps that regression loud instead of allowing sign-in to proceed
 * with no stored binding.
 */
const reparseRequestAttestation = (headers: Headers | undefined): ParsedAttestation => {
  const headerValue = headers?.get(ATTESTATION_HEADER_NAME) ?? undefined;
  if (headerValue === undefined) {
    throw new Error(
      `sendMagicLink reached without an '${ATTESTATION_HEADER_NAME}' header — the attestation plugin should have rejected this request`,
    );
  }
  try {
    return decodeAttestationHeader(headerValue);
  } catch (error) {
    if (error instanceof AttestationHeaderParseError || error instanceof AttestationParseError) {
      throw new Error(
        `sendMagicLink re-parse of '${ATTESTATION_HEADER_NAME}' failed (${error.code}: ${error.message}) — the attestation plugin should have rejected this request upstream`,
        { cause: error },
      );
    }
    throw error;
  }
};

interface PersistedMagicLinkArtefacts {
  readonly code: string;
}

/**
 * Persist the `(fph, pk)` pair from the request-time attestation against
 * BOTH the magic-link token's identifier (so `/magic-link/verify` can
 * DEVICE_MISMATCH a URL interceptor) AND a freshly-minted 6-digit backup
 * code (so `/magic-link/verify-by-code` can DEVICE_MISMATCH a code
 * interceptor). Returns the generated plaintext code so `sendMagicLink`
 * can hand it to the delivery adapter.
 *
 * Both writes must land before the email ships — a sent email with
 * either row missing would strand the user on that path (URL path
 * DEVICE_MISMATCHes against a missing attestation row; code path
 * INVALID_CODEs against a missing code row). Failing the outer
 * `sendMagicLink` on any write error is the right posture here.
 */
const persistMagicLinkArtefacts = async (
  token: string,
  headers: Headers | undefined,
  secret: string,
): Promise<PersistedMagicLinkArtefacts> => {
  const parsed = reparseRequestAttestation(headers);
  const tokenIdentifier = deriveTokenIdentifier(token);
  const expiresAt = new Date(Date.now() + MAGIC_LINK_EXPIRES_IN_SECONDS * 1000);
  const codeExpiresAt = new Date(Date.now() + MAGIC_LINK_CODE_EXPIRES_IN_SECONDS * 1000);
  await storeMagicLinkAttestation({
    tokenIdentifier,
    fingerprintHash: parsed.fingerprintHash,
    publicKeySPKI: parsed.publicKeySPKI,
    expiresAt,
  });
  const code = generateBackupCode();
  await storeMagicLinkCode({
    code,
    secret,
    plaintextToken: token,
    tokenIdentifier,
    fingerprintHash: parsed.fingerprintHash,
    publicKeySPKI: parsed.publicKeySPKI,
    expiresAt: codeExpiresAt,
  });
  return { code };
};

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
    //
    // Before the email goes out, the `(fph, pk)` from the request-time
    // attestation is persisted against the token's identifier so the
    // `ver:` binding at verify time can byte-compare against exactly the
    // device that requested the link. A write failure propagates and
    // refuses the email — a sent email with no stored attestation would
    // always DEVICE_MISMATCH at verify, stranding the user.
    sendMagicLink: async ({ email, token }, ctx) => {
      const { code } = await persistMagicLinkArtefacts(
        token,
        ctx?.request?.headers,
        env.BETTER_AUTH_SECRET,
      );
      const magicLinkURL = buildUniversalLinkURL(env, token).toString();
      await delivery.send({ email, token, magicLink: magicLinkURL, code });
    },
  });
