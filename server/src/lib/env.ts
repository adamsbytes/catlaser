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
  APPLE_TEAM_ID: string;
  GOOGLE_CLIENT_ID: string;
  MAGIC_LINK_UNIVERSAL_LINK_HOST: string;
  MAGIC_LINK_UNIVERSAL_LINK_PATH: string;
  PROVISIONING_TOKEN: string;
}

/**
 * Path served by the magic-link plugin's verify endpoint under
 * `AUTH_BASE_PATH`. The Universal Link path must NOT equal this — otherwise
 * the AASA-routed handler and the API handler would collide, defeating the
 * device-binding check. Kept as a module constant so the env validator and
 * the auth factory agree on a single source of truth.
 */
export const API_MAGIC_LINK_VERIFY_PATH = '/api/v1/auth/magic-link/verify';

/**
 * RFC 1035 host validator mirroring the iOS `AuthConfig.isPlausibleHost`
 * check. Accepts ASCII labels only (IDN would require Punycode), rejects
 * anything containing scheme/path/port/userinfo smuggling, caps at 253
 * characters. A host rejected on iOS must also be rejected here and vice
 * versa — otherwise the Universal Link round-trip is asymmetric.
 */
const HOST_LABEL_CHAR = /^[\d\-a-z]$/v;
const isHostLabel = (label: string): boolean => {
  if (label.length === 0 || label.length > 63) {
    return false;
  }
  if (label.startsWith('-') || label.endsWith('-')) {
    return false;
  }
  for (const char of label) {
    if (!HOST_LABEL_CHAR.test(char)) {
      return false;
    }
  }
  return true;
};
const isPlausibleHost = (candidate: string): boolean => {
  if (candidate.length === 0 || candidate.length > 253) {
    return false;
  }
  const labels = candidate.split('.');
  if (labels.length === 0) {
    return false;
  }
  return labels.every((label) => isHostLabel(label));
};

/**
 * Universal Link path validator. Must start with `/`, contain no query
 * separator, fragment, or whitespace, and must not collide with the API
 * verify endpoint. The collision check blocks a misconfiguration where the
 * AASA-registered path double-routes to the server-side verify handler,
 * which would let a browser fallback complete sign-in on a device that
 * never produced the original attestation.
 */
const DISALLOWED_PATH_CHAR = /[\s#?]/v;
const isPlausibleUniversalLinkPath = (path: string): boolean => {
  if (!path.startsWith('/')) {
    return false;
  }
  if (DISALLOWED_PATH_CHAR.test(path)) {
    return false;
  }
  return path !== API_MAGIC_LINK_VERIFY_PATH;
};

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
    // Apple Developer Team ID (10-character uppercase alphanumeric). This
    // pairs with `APPLE_APP_BUNDLE_IDENTIFIER` to form the `<TeamID>.<BundleID>`
    // appID strings that go in the AASA (`apple-app-site-association`)
    // file's `applinks.details[].appIDs` entries. iOS refuses to route a
    // Universal Link into the app if the AASA's appID doesn't exactly match
    // the app's own provisioned identifier — so this MUST match the Team ID
    // on the Apple Developer account the app is signed with. Validated at
    // process-start so a misconfigured deployment fails loudly rather than
    // silently publishing an AASA the installed app will reject.
    APPLE_TEAM_ID: z
      .string()
      .regex(
        /^[\dA-Z]{10}$/v,
        'APPLE_TEAM_ID must be exactly 10 uppercase-alphanumeric characters',
      ),
    // Google OAuth client ID (the iOS client type registered in Google Cloud
    // Console). ID tokens issued to the app carry `aud = <client_id>`; the
    // server pins the `aud` against this value via better-auth's default
    // Google verifier.
    GOOGLE_CLIENT_ID: z.string().min(1, 'GOOGLE_CLIENT_ID must not be empty'),
    // Universal Link host (iOS) / App Link host (Android) that receives
    // magic-link emails. The AASA/assetlinks registration here associates
    // the path with the app's bundle identifier, so iOS routes taps into
    // the app rather than Safari. The server uses this host to construct
    // the URL embedded in outgoing emails and to allowlist the
    // client-supplied `callbackURL` on `POST /sign-in/magic-link` —
    // rejecting any other host closes the phishing-relay takeover vector
    // where an attacker would coax the server into emailing a link that
    // lands on a host the attacker controls.
    MAGIC_LINK_UNIVERSAL_LINK_HOST: z
      .string()
      .transform((value) => value.trim().toLowerCase())
      .refine(isPlausibleHost, {
        message: 'must be a host-only ASCII DNS name (no scheme, port, path, or whitespace)',
      }),
    // Path segment served by the Universal Link handler (distinct from the
    // API verify endpoint). A browser that falls back here receives the
    // inert HTML handler in `universal-link.ts`. Validated at process-start
    // so a misconfiguration fails loudly instead of shipping emails with a
    // broken destination.
    MAGIC_LINK_UNIVERSAL_LINK_PATH: z.string().refine(isPlausibleUniversalLinkPath, {
      message: `must start with '/', contain no '?'/'#'/whitespace, and must not equal '${API_MAGIC_LINK_VERIFY_PATH}'`,
    }),
    // Shared secret presented by the device during the one-shot
    // provisioning call (`POST /api/v1/devices/provision`). The
    // factory image embeds this value in the device's first-boot
    // configuration; every subsequent device-to-server call is
    // authenticated by the device's own Ed25519 key, not by this
    // token. 32 bytes of entropy (as hex or base64) is the floor —
    // the value is essentially a production secret that, if leaked,
    // would let any caller register arbitrary devices under the
    // operator's tailnet. Validated at process-start so a blank or
    // weak token fails loudly.
    PROVISIONING_TOKEN: z
      .string()
      .min(32, 'PROVISIONING_TOKEN must be at least 32 characters of high-entropy secret'),
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
