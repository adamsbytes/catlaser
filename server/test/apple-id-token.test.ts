import { createHash } from 'node:crypto';
import { beforeAll, describe, expect, test } from 'bun:test';
import type { JWK } from 'jose';
import { SignJWT, exportJWK, generateKeyPair } from 'jose';
import {
  APPLE_MAX_TOKEN_AGE_SECONDS,
  type AppleJWKFetcher,
  verifyAppleIdToken,
} from '~/lib/apple-id-token.ts';

const APPLE_ISSUER = 'https://appleid.apple.com';
const BUNDLE_ID = 'com.catlaser.app.test';
const RAW_NONCE = 'raw-nonce-value-from-the-app';
const EXPECTED_NONCE_HASH = createHash('sha256').update(RAW_NONCE).digest('hex');

interface Fixture {
  readonly privateKey: CryptoKey;
  readonly publicJwk: JWK;
  readonly fetchJWKS: AppleJWKFetcher;
}

let fixture: Fixture;

beforeAll(async () => {
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = 'test-kid';
  publicJwk.alg = 'ES256';
  publicJwk.use = 'sig';
  // eslint-disable-next-line @typescript-eslint/require-await
  const fetchJWKS: AppleJWKFetcher = async () => [publicJwk];
  fixture = { privateKey, publicJwk, fetchJWKS };
});

interface SignOptions {
  readonly nonce?: string;
  readonly audience?: string;
  readonly issuer?: string;
  readonly issuedAtSeconds?: number;
  readonly expirationSeconds?: number;
  readonly kid?: string;
}

const signToken = async (options: SignOptions = {}): Promise<string> => {
  const nowSeconds = options.issuedAtSeconds ?? Math.floor(Date.now() / 1000);
  const exp = options.expirationSeconds ?? nowSeconds + 300;
  const builder = new SignJWT(options.nonce === undefined ? {} : { nonce: options.nonce })
    .setProtectedHeader({ alg: 'ES256', kid: options.kid ?? fixture.publicJwk.kid ?? 'test-kid' })
    .setIssuedAt(nowSeconds)
    .setExpirationTime(exp)
    .setIssuer(options.issuer ?? APPLE_ISSUER)
    .setAudience(options.audience ?? BUNDLE_ID)
    .setSubject('apple-user-subject');
  return await builder.sign(fixture.privateKey);
};

describe('apple ID token verifier: successful paths', () => {
  test('valid token with SHA-256 of raw nonce verifies', async () => {
    const token = await signToken({ nonce: EXPECTED_NONCE_HASH });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(true);
  });

  test('valid token without nonce requirement verifies when caller passes undefined', async () => {
    const token = await signToken({ nonce: 'anything' });
    const didVerify = await verifyAppleIdToken(token, undefined, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(true);
  });
});

describe('apple ID token verifier: nonce failure modes', () => {
  test('server hashes raw nonce before comparison — naive straight compare fails', async () => {
    // If the server naively compared rawNonce to the token's nonce claim (as
    // better-auth's default verifier does), a token whose claim equals the
    // RAW nonce would verify. It must not — the iOS client set
    // `request.nonce = sha256(rawNonce)` and Apple echoes that hash.
    const token = await signToken({ nonce: RAW_NONCE });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('token with mismatched hashed nonce fails', async () => {
    const token = await signToken({ nonce: 'deadbeef'.repeat(8) });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('token with no nonce claim fails when caller asserts a nonce', async () => {
    const token = await signToken();
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });
});

describe('apple ID token verifier: JWT integrity', () => {
  test('token with wrong issuer fails', async () => {
    const token = await signToken({
      nonce: EXPECTED_NONCE_HASH,
      issuer: 'https://attacker.example',
    });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('token with wrong audience fails', async () => {
    const token = await signToken({
      nonce: EXPECTED_NONCE_HASH,
      audience: 'com.attacker.app',
    });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('token older than max age fails', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const issuedAtSeconds = nowSeconds - (APPLE_MAX_TOKEN_AGE_SECONDS + 60);
    const token = await signToken({
      nonce: EXPECTED_NONCE_HASH,
      issuedAtSeconds,
      expirationSeconds: issuedAtSeconds + APPLE_MAX_TOKEN_AGE_SECONDS + 120,
    });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
      nowSeconds: () => nowSeconds,
    });
    expect(didVerify).toBe(false);
  });

  test('expired token fails', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const issuedAtSeconds = nowSeconds - 120;
    const token = await signToken({
      nonce: EXPECTED_NONCE_HASH,
      issuedAtSeconds,
      expirationSeconds: nowSeconds - 60,
    });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
      nowSeconds: () => nowSeconds,
    });
    expect(didVerify).toBe(false);
  });

  test('token signed by a different key fails', async () => {
    const other = await generateKeyPair('ES256', { extractable: true });
    const token = await new SignJWT({ nonce: EXPECTED_NONCE_HASH })
      .setProtectedHeader({ alg: 'ES256', kid: fixture.publicJwk.kid ?? 'test-kid' })
      .setIssuedAt()
      .setExpirationTime('5m')
      .setIssuer(APPLE_ISSUER)
      .setAudience(BUNDLE_ID)
      .setSubject('apple-user-subject')
      .sign(other.privateKey);
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('token with unknown kid (no matching JWK) fails', async () => {
    const token = await signToken({ nonce: EXPECTED_NONCE_HASH, kid: 'does-not-exist' });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('completely malformed token fails (three-segment JOSE guard)', async () => {
    const didVerify = await verifyAppleIdToken('not.a.jwt.value', RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: fixture.fetchJWKS,
    });
    expect(didVerify).toBe(false);
  });

  test('JWKS fetch failure is swallowed and maps to false', async () => {
    const token = await signToken({ nonce: EXPECTED_NONCE_HASH });
    const didVerify = await verifyAppleIdToken(token, RAW_NONCE, {
      audience: BUNDLE_ID,
      fetchJWKS: async () => {
        await Promise.resolve();
        throw new Error('network outage');
      },
    });
    expect(didVerify).toBe(false);
  });
});
