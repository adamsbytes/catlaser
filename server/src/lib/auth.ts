import type { Auth, BetterAuthOptions } from 'better-auth';
import { betterAuth } from 'better-auth';
import { drizzleAdapter } from 'better-auth/adapters/drizzle';
import { bearer } from 'better-auth/plugins';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';

export const AUTH_BASE_PATH: string = '/api/v1/auth';

const options: BetterAuthOptions = {
  appName: 'catlaser',
  baseURL: env.BETTER_AUTH_URL,
  basePath: AUTH_BASE_PATH,
  secret: env.BETTER_AUTH_SECRET,
  database: drizzleAdapter(db, { provider: 'pg' }),
  trustedOrigins: [...env.TRUSTED_ORIGINS],
  plugins: [bearer({ requireSignature: true })],
  advanced: {
    // Force origin/CSRF enforcement in every environment. better-auth otherwise
    // auto-skips when NODE_ENV === "test", which would let tests pass while
    // production fails closed differently — a coverage gap we refuse.
    disableOriginCheck: false,
    disableCSRFCheck: false,
  },
};

export const auth: Auth = betterAuth(options);
