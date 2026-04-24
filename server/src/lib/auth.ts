import type { Auth, BetterAuthOptions } from 'better-auth';
import { betterAuth } from 'better-auth';
import { drizzleAdapter } from 'better-auth/adapters/drizzle';
import { bearer } from 'better-auth/plugins';
import { buildBeforeHook } from '~/lib/auth-hooks.ts';
import { deviceAttestationPlugin } from '~/lib/attestation-plugin.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery } from '~/lib/magic-link.ts';
import { buildMagicLinkPlugin, pinoMagicLinkDelivery } from '~/lib/magic-link.ts';
import { buildMagicLinkCodePlugin } from '~/lib/magic-link-code-plugin.ts';
import type { NowDateFn } from '~/lib/rate-limit.ts';
import { buildEmailRateLimitPlugin } from '~/lib/rate-limit.ts';
import type { SocialProviderOverrides } from '~/lib/social-providers.ts';
import { buildSocialProviders } from '~/lib/social-providers.ts';

/**
 * Headers the coordination server trusts to carry the originating client
 * IP. Ordered by preference: `cf-connecting-ip` is the canonical header
 * Cloudflare Tunnel sets on the origin side (ADR-006) — it carries the
 * real public IP after CF has stripped any forged upstream values. We
 * include `x-forwarded-for` as a fallback so the server remains usable
 * in environments without a CF frontend (local docker, dev behind an
 * ordinary reverse proxy) without compromising the CF posture — once CF
 * is in front, `cf-connecting-ip` is always present and wins on the
 * first-header-that-parses rule in `@better-auth/core`'s `getIp`.
 */
const TRUSTED_IP_ADDRESS_HEADERS = ['cf-connecting-ip', 'x-forwarded-for'] as const;

/**
 * Per-IP window on sign-in paths. `window: 60, max: 10` is ~6x looser
 * than better-auth's default 3/10s special rule for `/sign-in/*`, which
 * would trip on any realistic concurrent-test scenario, and ~10x
 * tighter than the global default `100/10s`. The goal is a quiet DoS
 * floor, not an enumeration defence — the per-email plugin handles the
 * enumeration half. Response on exceed is a loud 429 (better-auth
 * built-in), which is correct here because the key is the IP, not an
 * email; a 429 reveals that the caller's IP has been hammering, not
 * anything about which email it targeted.
 */
const SIGN_IN_RATE_LIMIT: { readonly window: number; readonly max: number } = {
  window: 60,
  max: 10,
};

export const AUTH_BASE_PATH: string = '/api/v1/auth';

export interface CreateAuthOverrides extends SocialProviderOverrides {
  readonly magicLinkDelivery?: MagicLinkDelivery;
  /**
   * Test-only injection seam for the attestation plugin's skew clock.
   * Integration tests drive `req:` / `out:` / `api:` skew behaviour
   * deterministically against fixed attestation timestamps by handing
   * in a frozen-clock closure; production omits the field and the
   * plugin reads the real wall clock via `defaultNowSeconds`.
   */
  readonly attestationNowSeconds?: NowSecondsFn;
  /**
   * Test-only injection seam for the per-email rate-limit plugin's
   * clock. Same contract as `attestationNowSeconds` — production omits
   * and the plugin reads the real wall clock, tests inject a frozen
   * `Date` so window-reset behaviour is deterministic under concurrent
   * acquires.
   */
  readonly rateLimitNowDate?: NowDateFn;
  /**
   * Test-only override for the per-email window. Dedicated rate-limit
   * suites shrink the window to keep the ±seconds arithmetic cheap
   * without changing production behaviour. Production deployments read
   * `EMAIL_RATE_LIMIT_WINDOW_SECONDS` from the module default.
   */
  readonly rateLimitWindowSeconds?: number;
  /**
   * Test-only override for the per-email max. Mirrors
   * `rateLimitWindowSeconds` — production reads the module default.
   */
  readonly rateLimitMax?: number;
}

/**
 * Construct the better-auth instance. Lives behind a factory so tests can
 * inject overrides (fake Apple JWKS, frozen clock, recording magic-link
 * delivery) without mutating module state. Production code calls
 * `createAuth()` once and exports `auth`.
 */
export const createAuth = (overrides: CreateAuthOverrides = {}): Auth => {
  const delivery = overrides.magicLinkDelivery ?? pinoMagicLinkDelivery(env);
  const attestationOptions =
    overrides.attestationNowSeconds === undefined
      ? {}
      : { nowSeconds: overrides.attestationNowSeconds };
  const rateLimitPlugin = buildEmailRateLimitPlugin({
    secret: env.BETTER_AUTH_SECRET,
    ...(overrides.rateLimitNowDate === undefined ? {} : { nowDate: overrides.rateLimitNowDate }),
    ...(overrides.rateLimitWindowSeconds === undefined
      ? {}
      : { windowSeconds: overrides.rateLimitWindowSeconds }),
    ...(overrides.rateLimitMax === undefined ? {} : { max: overrides.rateLimitMax }),
  });
  const options: BetterAuthOptions = {
    appName: 'catlaser',
    baseURL: env.BETTER_AUTH_URL,
    basePath: AUTH_BASE_PATH,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db, { provider: 'pg' }),
    trustedOrigins: [...env.TRUSTED_ORIGINS],
    plugins: [
      bearer({ requireSignature: true }),
      buildMagicLinkPlugin(env, delivery),
      // Backup-code sibling of the magic-link plugin. Registers
      // `POST /magic-link/verify-by-code` and lands on the same
      // better-auth verification row as `GET /magic-link/verify` —
      // redeeming either path makes the other inert. Wired AFTER
      // `buildMagicLinkPlugin` so the plugin-registration order
      // reads URL path, then code path, matching the paired flow.
      buildMagicLinkCodePlugin(env),
      deviceAttestationPlugin(attestationOptions),
      // Per-email enumeration-resistant cooldown. Runs AFTER the
      // attestation plugin by virtue of plugin-registration order —
      // a bad attestation 401s before a rate-limit row is written,
      // and a captured-attestation replay still gets swallowed here.
      rateLimitPlugin,
    ],
    socialProviders: buildSocialProviders(env, overrides),
    hooks: {
      before: buildBeforeHook(env),
    },
    // Per-(IP, path) floor. Enabled in EVERY environment — better-auth's
    // default `isProduction` gating would leave dev and test without
    // the limiter wired up, which inverts the "test mirrors prod"
    // invariant and lets a regression land without a failing CI signal.
    // `storage: 'database'` persists counters across restart and across
    // replicas, using the `rate_limit` table registered in `db.ts` with
    // column shape that exactly matches `@better-auth/core`'s expected
    // `rateLimit` model.
    rateLimit: {
      enabled: true,
      storage: 'database',
      // Global default window — applies to any path not matched by
      // `customRules`. 100 req / 10s matches better-auth's stock
      // tuning and is generous enough for ordinary authenticated
      // traffic without relaxing the sign-in floor below.
      window: 10,
      max: 100,
      customRules: {
        '/sign-in/magic-link': SIGN_IN_RATE_LIMIT,
        '/sign-in/social': SIGN_IN_RATE_LIMIT,
        // Per-IP floor on the backup-code path. The per-code
        // `attempts_remaining` counter is the primary brute-force
        // defence; this floor exists to absorb a distributed search
        // (one attempt per code across many victims) that would
        // otherwise bypass the per-code counter. Matches the sibling
        // sign-in endpoints' posture.
        '/magic-link/verify-by-code': SIGN_IN_RATE_LIMIT,
      },
    },
    advanced: {
      // Force origin/CSRF enforcement in every environment. better-auth otherwise
      // auto-skips when NODE_ENV === "test", which would let tests pass while
      // production fails closed differently — a coverage gap we refuse.
      disableOriginCheck: false,
      disableCSRFCheck: false,
      ipAddress: {
        // Tell the built-in `getIp` to read the originating client IP
        // from Cloudflare's `cf-connecting-ip` (primary, ADR-006) and
        // fall through to `x-forwarded-for` on non-CF deployments. A
        // sibling comment on `TRUSTED_IP_ADDRESS_HEADERS` covers the
        // trust model. Without this override, `getIp` falls through
        // to localhost in dev/test, which would collapse every test's
        // rate-limit key onto the same bucket.
        ipAddressHeaders: [...TRUSTED_IP_ADDRESS_HEADERS],
      },
    },
  };
  return betterAuth(options);
};

export const auth: Auth = createAuth();
