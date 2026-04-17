import { z } from 'zod';

export interface Env {
  NODE_ENV: 'development' | 'test' | 'production';
  PORT: number;
  DATABASE_URL: string;
  BETTER_AUTH_SECRET: string;
  BETTER_AUTH_URL: string;
  TRUSTED_ORIGINS: readonly string[];
  APPLE_CLIENT_ID: string;
  APPLE_APP_BUNDLE_IDENTIFIER: string;
  GOOGLE_CLIENT_ID: string;
}

const parseEnv = (source: Record<string, string | undefined>): Env => {
  const schema = z.object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().min(1).max(65_535).default(3000),
    DATABASE_URL: z.url(),
    BETTER_AUTH_SECRET: z.string().min(32, 'BETTER_AUTH_SECRET must be at least 32 characters'),
    BETTER_AUTH_URL: z.url(),
    TRUSTED_ORIGINS: z
      .string()
      .min(1)
      .transform((value) =>
        value
          .split(',')
          .map((entry) => entry.trim())
          .filter((entry) => entry.length > 0),
      )
      .pipe(z.array(z.string().min(1)).min(1)),
    // Apple "Services ID" (the identifier registered with Apple Developer).
    // Used as the OAuth `client_id` when the redirect flow is exercised, which
    // the app does not use — but better-auth requires the value in the
    // provider config, and it is echoed into the Apple ID token's `aud` claim
    // for the web-sign-in case that may exist in future.
    APPLE_CLIENT_ID: z.string().min(1, 'APPLE_CLIENT_ID must not be empty'),
    // Apple app bundle identifier (e.g. com.catlaser.app). Native ID tokens
    // come back with `aud = <bundle id>`, so this is what the server pins
    // against when verifying Apple tokens from the app.
    APPLE_APP_BUNDLE_IDENTIFIER: z.string().min(1, 'APPLE_APP_BUNDLE_IDENTIFIER must not be empty'),
    // Google OAuth client ID (the iOS client type registered in Google Cloud
    // Console). ID tokens issued to the app carry `aud = <client_id>`; the
    // server pins the `aud` against this value via better-auth's default
    // Google verifier.
    GOOGLE_CLIENT_ID: z.string().min(1, 'GOOGLE_CLIENT_ID must not be empty'),
  });

  const result = schema.safeParse(source);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => {
        const path = issue.path.length > 0 ? issue.path.join('.') : '<root>';
        return `  - ${path}: ${issue.message}`;
      })
      .join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  return result.data;
};

export const env: Env = parseEnv(process.env);
