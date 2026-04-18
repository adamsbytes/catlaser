import type { Auth, BetterAuthOptions } from 'better-auth';
import { betterAuth } from 'better-auth';
import { drizzleAdapter } from 'better-auth/adapters/drizzle';
import { bearer } from 'better-auth/plugins';
import { buildBeforeHook } from '~/lib/auth-hooks.ts';
import { deviceAttestationPlugin } from '~/lib/attestation-plugin.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery } from '~/lib/magic-link.ts';
import { buildMagicLinkPlugin, pinoMagicLinkDelivery } from '~/lib/magic-link.ts';
import type { SocialProviderOverrides } from '~/lib/social-providers.ts';
import { buildSocialProviders } from '~/lib/social-providers.ts';

export const AUTH_BASE_PATH: string = '/api/v1/auth';

export interface CreateAuthOverrides extends SocialProviderOverrides {
  readonly magicLinkDelivery?: MagicLinkDelivery;
}

/**
 * Construct the better-auth instance. Lives behind a factory so tests can
 * inject overrides (fake Apple JWKS, frozen clock, recording magic-link
 * delivery) without mutating module state. Production code calls
 * `createAuth()` once and exports `auth`.
 */
export const createAuth = (overrides: CreateAuthOverrides = {}): Auth => {
  const delivery = overrides.magicLinkDelivery ?? pinoMagicLinkDelivery(env);
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
      deviceAttestationPlugin(),
    ],
    socialProviders: buildSocialProviders(env, overrides),
    hooks: {
      before: buildBeforeHook(env),
    },
    advanced: {
      // Force origin/CSRF enforcement in every environment. better-auth otherwise
      // auto-skips when NODE_ENV === "test", which would let tests pass while
      // production fails closed differently — a coverage gap we refuse.
      disableOriginCheck: false,
      disableCSRFCheck: false,
    },
  };
  return betterAuth(options);
};

export const auth: Auth = createAuth();
