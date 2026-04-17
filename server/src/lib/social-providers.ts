import type { SocialProviders } from '@better-auth/core/social-providers';
import type { AppleIdTokenVerifyOptions } from '~/lib/apple-id-token.ts';
import { verifyAppleIdToken } from '~/lib/apple-id-token.ts';
import type { Env } from '~/lib/env.ts';

/**
 * Assemble the `socialProviders` record for Apple and Google.
 *
 * Both providers run in ID-token-exchange mode: the native app (`AppleID
 * TokenProvider` / `GoogleIDTokenProvider` on iOS, Credential Manager on
 * Android) obtains an ID token from the provider and posts it to
 * `/sign-in/social`. The server never orchestrates the authorization-code
 * redirect flow for these providers, so no OAuth redirect URIs, state, or
 * client secrets are required here.
 *
 * Apple's default better-auth verifier cannot be used directly: Apple issues
 * ID tokens whose `nonce` claim is the SHA-256 of the `raw` nonce value sent
 * on the authorization request, but our server receives the raw nonce in
 * `body.idToken.nonce` so the three-way match against the `sis:` attestation
 * binding is possible. The Apple provider therefore plugs in a custom
 * `verifyIdToken` that pre-hashes the raw nonce before comparison. Google
 * echoes the raw nonce verbatim in its ID token and needs no transformation.
 */
export const buildSocialProviders = (
  env: Env,
  overrides: SocialProviderOverrides = {},
): SocialProviders => {
  const appleVerifyOptions: AppleIdTokenVerifyOptions = {
    audience: env.APPLE_APP_BUNDLE_IDENTIFIER,
    fetchJWKS: overrides.appleFetchJWKS,
    nowSeconds: overrides.appleNowSeconds,
  };
  return {
    apple: {
      clientId: env.APPLE_CLIENT_ID,
      appBundleIdentifier: env.APPLE_APP_BUNDLE_IDENTIFIER,
      verifyIdToken: async (token, nonce) =>
        await verifyAppleIdToken(token, nonce, appleVerifyOptions),
    },
    google: {
      clientId: env.GOOGLE_CLIENT_ID,
    },
  };
};

/**
 * Test seams. In production nothing is passed; the Apple verifier falls back
 * to a global-`fetch`-backed JWKS load and the real wall clock.
 */
export interface SocialProviderOverrides {
  readonly appleFetchJWKS?: AppleIdTokenVerifyOptions['fetchJWKS'];
  readonly appleNowSeconds?: AppleIdTokenVerifyOptions['nowSeconds'];
}
