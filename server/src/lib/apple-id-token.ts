import { createHash, timingSafeEqual } from 'node:crypto';
import type { JWK, JWTVerifyOptions } from 'jose';
import { decodeProtectedHeader, importJWK, jwtVerify } from 'jose';

/**
 * Verify an Apple ID token under the catlaser social-sign-in contract.
 *
 * Why this exists rather than relying on better-auth's default Apple verifier:
 *
 * The iOS `AppleIDTokenProvider` calls `ASAuthorizationAppleIDProvider` with
 * `request.nonce = sha256Hex(rawNonce)` — Apple requires the hashed form on
 * the authorization request, and the resulting ID token's `nonce` claim is
 * that hash. Our server, however, needs the RAW nonce in the request body so
 * it can be three-way matched against the `sis:<rawNonce>` attestation
 * binding (both sides use the raw value; only Apple interposes a hash).
 *
 * Better-auth's default Apple verifier does a straight-equals check between
 * `body.idToken.nonce` and the ID-token `nonce` claim — that fails for us
 * because one side is `raw` and the other is `sha256(raw)`. This verifier
 * fixes that: it hashes the supplied nonce before comparison. Google needs no
 * such transformation and is handled by better-auth's default Google verifier.
 *
 * Everything else (JWK fetch, issuer pin, audience pin, signature verify,
 * 1-hour max token age) matches the default verifier's semantics so the
 * cryptographic posture is unchanged.
 */

const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_ISSUER = 'https://appleid.apple.com';
/** Max token age, matching better-auth's default Apple provider. */
export const APPLE_MAX_TOKEN_AGE_SECONDS = 60 * 60;

export type AppleJWKFetcher = (url: string) => Promise<readonly JWK[]>;

export interface AppleIdTokenVerifyOptions {
  /** Value to pin the ID token's `aud` claim against — the app bundle identifier. */
  readonly audience: string;
  /**
   * Override for the JWKS fetcher. In production this is left undefined and
   * a global-`fetch`-backed implementation is used. Tests inject a fake.
   */
  readonly fetchJWKS?: AppleJWKFetcher | undefined;
  /**
   * Wall-clock override used to freeze `maxTokenAge` checks in tests.
   * Accepts Unix seconds.
   */
  readonly nowSeconds?: (() => number) | undefined;
}

const sha256Hex = (input: string): string =>
  createHash('sha256').update(input, 'utf8').digest('hex');

const constantTimeStringEquals = (a: string, b: string): boolean => {
  const aBytes = Buffer.from(a, 'utf8');
  const bBytes = Buffer.from(b, 'utf8');
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

const defaultFetchJWKS: AppleJWKFetcher = async (url) => {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`JWKS fetch returned HTTP ${response.status.toString()}`);
  }
  const body: unknown = await response.json();
  if (body === null || typeof body !== 'object' || !('keys' in body)) {
    throw new TypeError('JWKS response has no keys');
  }
  const { keys } = body as { keys: unknown };
  if (!Array.isArray(keys)) {
    throw new TypeError('JWKS response keys is not an array');
  }
  // We re-expose each key's shape only after verifying it is an object; the
  // consumer filters by kid match and passes the survivor to importJWK, which
  // itself validates the key structure cryptographically.
  for (const candidate of keys) {
    if (candidate === null || typeof candidate !== 'object') {
      throw new TypeError('JWKS response contains a non-object key');
    }
  }
  return keys as readonly JWK[];
};

interface ExtractedHeader {
  readonly kid: string;
  readonly alg: string;
}

const extractProtectedHeader = (token: string): ExtractedHeader | undefined => {
  const header = decodeProtectedHeader(token);
  const { kid, alg } = header;
  if (typeof kid !== 'string' || kid.length === 0) {
    return undefined;
  }
  if (typeof alg !== 'string' || alg.length === 0) {
    return undefined;
  }
  return { kid, alg };
};

const findJWKForKid = async (fetchJWKS: AppleJWKFetcher, kid: string): Promise<JWK | undefined> => {
  const keys = await fetchJWKS(APPLE_JWKS_URL);
  return keys.find((candidate) => candidate.kid === kid);
};

const buildVerifyOptions = (options: AppleIdTokenVerifyOptions, alg: string): JWTVerifyOptions => {
  const verifyOptions: JWTVerifyOptions = {
    algorithms: [alg],
    issuer: APPLE_ISSUER,
    audience: options.audience,
    maxTokenAge: `${APPLE_MAX_TOKEN_AGE_SECONDS.toString()}s`,
  };
  if (options.nowSeconds !== undefined) {
    verifyOptions.currentDate = new Date(options.nowSeconds() * 1000);
  }
  return verifyOptions;
};

const nonceMatches = (payload: Record<string, unknown>, rawNonce: string): boolean => {
  const claimNonce = payload['nonce'];
  if (typeof claimNonce !== 'string') {
    return false;
  }
  return constantTimeStringEquals(claimNonce, sha256Hex(rawNonce));
};

/**
 * Returns `true` if the ID token verifies and the pre-hashed raw nonce (if
 * provided) matches the token's `nonce` claim in constant time. Returns
 * `false` on any failure — the caller should map that to a 401.
 *
 * This mirrors better-auth's `Provider.verifyIdToken` contract: never throw.
 */
export const verifyAppleIdToken = async (
  token: string,
  rawNonce: string | undefined,
  options: AppleIdTokenVerifyOptions,
): Promise<boolean> => {
  try {
    const extracted = extractProtectedHeader(token);
    if (extracted === undefined) {
      return false;
    }
    const fetchJWKS = options.fetchJWKS ?? defaultFetchJWKS;
    const jwk = await findJWKForKid(fetchJWKS, extracted.kid);
    if (jwk === undefined) {
      return false;
    }
    const key = await importJWK(jwk, jwk.alg ?? extracted.alg);
    const { payload } = await jwtVerify(token, key, buildVerifyOptions(options, extracted.alg));
    if (rawNonce === undefined) {
      return true;
    }
    return nonceMatches(payload, rawNonce);
  } catch {
    return false;
  }
};
