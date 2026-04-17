import { createHash } from 'node:crypto';
import { beforeAll, describe, expect, test } from 'bun:test';
import type { JWK } from 'jose';
import { SignJWT, exportJWK, generateKeyPair } from 'jose';
import { z } from 'zod';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import {
  ATTESTATION_VERSION,
  FINGERPRINT_HASH_BYTES,
  MIN_PUBLIC_KEY_BYTES,
  encodeAttestationHeader,
} from '~/lib/attestation-header.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/auth-hooks.ts';
import { createAuth } from '~/lib/auth.ts';
import { env } from '~/lib/env.ts';

/**
 * End-to-end tests for `/sign-in/social`:
 *
 * - The before-hook enforces the attestation three-way-match contract.
 * - better-auth's route + the Apple verifier override accept well-formed
 *   native ID tokens once the hook has let them through.
 *
 * Every test goes through `handle(...)`-equivalent plumbing via the
 * `createAuth()` factory — no better-auth internals are bypassed, and the
 * hook cannot accidentally be short-circuited by a future refactor.
 */

const APPLE_ISSUER = 'https://appleid.apple.com';
const AUTH_BASE = '/api/v1/auth';
const socialURL = `http://localhost${AUTH_BASE}/sign-in/social`;
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';

interface AppleFixture {
  readonly privateKey: CryptoKey;
  readonly publicJwk: JWK;
}
let appleFixture: AppleFixture;

beforeAll(async () => {
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = 'apple-test-kid';
  publicJwk.alg = 'ES256';
  publicJwk.use = 'sig';
  appleFixture = { privateKey, publicJwk };
});

const buildAppleJWKSOverride = () =>
  ({
    // eslint-disable-next-line @typescript-eslint/require-await
    appleFetchJWKS: async () => [appleFixture.publicJwk],
  }) as const;

const signAppleToken = async (nonce: string, email = 'apple-user@example.com'): Promise<string> => {
  const hashed = createHash('sha256').update(nonce).digest('hex');
  return await new SignJWT({
    nonce: hashed,
    email,
    email_verified: true,
  })
    .setProtectedHeader({ alg: 'ES256', kid: appleFixture.publicJwk.kid ?? 'apple-test-kid' })
    .setIssuedAt()
    .setExpirationTime('10m')
    .setIssuer(APPLE_ISSUER)
    .setAudience(env.APPLE_APP_BUNDLE_IDENTIFIER)
    .setSubject('apple-user-123')
    .sign(appleFixture.privateKey);
};

interface BuildHeaderOpts {
  readonly binding: AttestationBinding;
  readonly overrideFph?: Uint8Array;
  readonly overridePk?: Uint8Array;
  readonly overrideSig?: Uint8Array;
  readonly overrideVersion?: number;
}

const buildAttestationHeader = (opts: BuildHeaderOpts): string =>
  encodeAttestationHeader({
    version: opts.overrideVersion ?? ATTESTATION_VERSION,
    fingerprintHash: opts.overrideFph ?? new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xab),
    publicKeySPKI: opts.overridePk ?? new Uint8Array(MIN_PUBLIC_KEY_BYTES + 32).fill(0x11),
    binding: opts.binding,
    signature: opts.overrideSig ?? new Uint8Array([0x30, 0x44, 0x02, 0x20, 0x01, 0x02, 0x03]),
  });

interface SendOpts {
  readonly headers?: Record<string, string>;
  readonly body: unknown;
  readonly useAuth?: ReturnType<typeof createAuth>;
}

const defaultHeaders: Record<string, string> = {
  'Content-Type': 'application/json',
  Origin: trustedOrigin,
};

const postSocial = async (opts: SendOpts): Promise<{ response: Response; body: unknown }> => {
  const auth = opts.useAuth ?? createAuth();
  const init: RequestInit = {
    method: 'POST',
    headers: { ...defaultHeaders, ...opts.headers },
    body: JSON.stringify(opts.body),
  };
  const response = await auth.handler(new Request(socialURL, init));
  const text = await response.text();
  const parsedBody: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { response, body: parsedBody };
};

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

describe('sign-in/social: attestation required', () => {
  test('missing x-device-attestation header returns 401 ATTESTATION_REQUIRED', async () => {
    const { response, body } = await postSocial({
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_REQUIRED');
  });

  test('empty x-device-attestation header returns 401 ATTESTATION_REQUIRED', async () => {
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: '   ' },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_REQUIRED');
  });
});

describe('sign-in/social: attestation structural failure', () => {
  test('garbage base64 returns 401 ATTESTATION_INVALID', async () => {
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: 'not@valid-base64' },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_INVALID');
  });

  test('v != 3 returns 401 ATTESTATION_INVALID', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
      overrideVersion: 2,
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_INVALID');
  });

  test('bnd parse failure inside a well-formed envelope returns 401 ATTESTATION_INVALID', async () => {
    // Hand-build a header whose outer envelope is valid but whose bnd value
    // has a leading-zero timestamp — exercises the AttestationParseError
    // propagation path from decodeAttestationBinding up through the hook.
    const fph = Buffer.from(new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xa))
      .toString('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');
    const pk = Buffer.from(new Uint8Array(MIN_PUBLIC_KEY_BYTES + 32).fill(0x11)).toString('base64');
    const sig = Buffer.from(new Uint8Array([0x01])).toString('base64');
    const inner = `{"bnd":"req:01","fph":"${fph}","pk":"${pk}","sig":"${sig}","v":3}`;
    const header = Buffer.from(inner, 'utf8').toString('base64');
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_INVALID');
  });
});

describe('sign-in/social: binding mismatch', () => {
  test('req: binding returns 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'request', timestamp: 1_734_489_600n },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('ver: binding returns 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'verify', token: 'magic-token' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('out: binding returns 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'signOut', timestamp: 1_734_489_600n },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: 'raw' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });
});

describe('sign-in/social: nonce three-way match', () => {
  test('missing body.idToken.nonce returns 401 ID_TOKEN_NONCE_REQUIRED', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ID_TOKEN_NONCE_REQUIRED');
  });

  test('empty body.idToken.nonce returns 401 ID_TOKEN_NONCE_REQUIRED', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: { provider: 'apple', idToken: { token: 'x', nonce: '' } },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ID_TOKEN_NONCE_REQUIRED');
  });

  test('sis: raw nonce != body.idToken.nonce returns 401 ATTESTATION_NONCE_MISMATCH', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'attestation-nonce' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: {
        provider: 'apple',
        idToken: { token: 'x', nonce: 'different-body-nonce' },
      },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code).toBe('ATTESTATION_NONCE_MISMATCH');
  });

  test('missing body entirely returns 401 ID_TOKEN_NONCE_REQUIRED after binding ok', async () => {
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const auth = createAuth();
    const init: RequestInit = {
      method: 'POST',
      headers: { ...defaultHeaders, [ATTESTATION_HEADER_NAME]: header },
      // No body at all — better-auth's content-type parser should return an
      // empty object to the hook; our hook then reports missing nonce.
    };
    const response = await auth.handler(new Request(socialURL, init));
    expect(response.status).toBe(401);
    const text = await response.text();
    const parsed = errorBodyShape.parse(JSON.parse(text));
    expect(parsed.code).toBe('ID_TOKEN_NONCE_REQUIRED');
  });
});

describe('sign-in/social: hook pass-through to better-auth', () => {
  test('valid attestation but unknown provider falls through to better-auth NOT_FOUND', async () => {
    // A fully valid attestation + matching nonce should pass the hook; the
    // request then reaches better-auth, which rejects an unregistered
    // provider with NOT_FOUND / PROVIDER_NOT_FOUND. This proves the hook's
    // happy path lets the request through rather than short-circuiting.
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: {
        provider: 'facebook',
        idToken: { token: 'x', nonce: 'raw' },
      },
    });
    expect(response.status).toBe(404);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code ?? '').not.toBe('ATTESTATION_NONCE_MISMATCH');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_BINDING_MISMATCH');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_REQUIRED');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_INVALID');
  });

  test('valid attestation but unverifiable Apple token falls through to INVALID_TOKEN', async () => {
    // Hook passes; better-auth invokes our Apple verifier; verifier fails
    // because the token is not a real JWT. Response is 401 but NOT one of
    // our attestation codes.
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const { response, body } = await postSocial({
      headers: { [ATTESTATION_HEADER_NAME]: header },
      body: {
        provider: 'apple',
        idToken: { token: 'not.a.real.jwt', nonce: 'raw' },
      },
    });
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    expect(parsed.code ?? '').not.toBe('ATTESTATION_REQUIRED');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_INVALID');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_BINDING_MISMATCH');
    expect(parsed.code ?? '').not.toBe('ATTESTATION_NONCE_MISMATCH');
    expect(parsed.code ?? '').not.toBe('ID_TOKEN_NONCE_REQUIRED');
  });

  test('hook does not run on other auth endpoints', async () => {
    // The hook matches exactly ctx.path === "/sign-in/social". A GET to
    // /get-session must not require an attestation header.
    const auth = createAuth();
    const response = await auth.handler(new Request(`http://localhost${AUTH_BASE}/get-session`));
    expect(response.status).toBe(200);
  });

  test('a real Apple ID token + matching nonce signs the user in and returns a bearer', async () => {
    // This exercises the full three-way-match under the Apple-provider
    // nonce-hashing override:
    //
    // 1. `body.idToken.nonce` = raw value committed by the app.
    // 2. Attestation `bnd` = `sis:<raw>` — hook verifies match #1 == #3.
    // 3. ID token `nonce` claim = sha256(raw) — Apple's verifier hashes
    //    the raw body nonce and compares.
    //
    // All three agree → better-auth issues a session.
    const rawNonce = 'e2e-nonce-01';
    const token = await signAppleToken(rawNonce);
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce },
    });
    const auth = createAuth(buildAppleJWKSOverride());
    const init: RequestInit = {
      method: 'POST',
      headers: { ...defaultHeaders, [ATTESTATION_HEADER_NAME]: header },
      body: JSON.stringify({
        provider: 'apple',
        idToken: { token, nonce: rawNonce },
      }),
    };
    const response = await auth.handler(new Request(socialURL, init));
    expect(response.status).toBe(200);
    const text = await response.text();
    const json = z
      .object({
        redirect: z.boolean(),
        token: z.string().min(1),
        user: z.looseObject({ id: z.string().min(1), email: z.string().optional() }),
      })
      .parse(JSON.parse(text));
    expect(json.redirect).toBe(false);
    expect(json.token.length).toBeGreaterThan(0);
    // bearer plugin also mirrors the session token on the `set-auth-token`
    // response header for platforms that prefer to read it there.
    expect(response.headers.get('set-auth-token')?.length ?? 0).toBeGreaterThan(0);
  });

  test('a raw (un-hashed) nonce in the Apple token fails the verifier even when hook passes', async () => {
    // Regression guard against the class of bug that motivates the custom
    // Apple verifier: if we ever reverted to better-auth's default verifier
    // (straight compare), a token whose `nonce` claim equals the raw nonce
    // would verify. It must not.
    const rawNonce = 'e2e-nonce-02';
    const token = await new SignJWT({ nonce: rawNonce })
      .setProtectedHeader({ alg: 'ES256', kid: appleFixture.publicJwk.kid ?? 'apple-test-kid' })
      .setIssuedAt()
      .setExpirationTime('10m')
      .setIssuer(APPLE_ISSUER)
      .setAudience(env.APPLE_APP_BUNDLE_IDENTIFIER)
      .setSubject('apple-user-456')
      .sign(appleFixture.privateKey);
    const header = buildAttestationHeader({
      binding: { tag: 'social', rawNonce },
    });
    const auth = createAuth(buildAppleJWKSOverride());
    const init: RequestInit = {
      method: 'POST',
      headers: { ...defaultHeaders, [ATTESTATION_HEADER_NAME]: header },
      body: JSON.stringify({
        provider: 'apple',
        idToken: { token, nonce: rawNonce },
      }),
    };
    const response = await auth.handler(new Request(socialURL, init));
    expect(response.status).toBe(401);
  });
});
