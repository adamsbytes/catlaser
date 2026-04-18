import { describe, expect, test } from 'bun:test';
import { sign as cryptoSign } from 'node:crypto';
import { z } from 'zod';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import {
  ATTESTATION_VERSION,
  FINGERPRINT_HASH_BYTES,
  encodeAttestationHeader,
} from '~/lib/attestation-header.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { EC_P256_SPKI_PREFIX, EC_P256_SPKI_TOTAL_BYTES } from '~/lib/attestation-verify.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { env } from '~/lib/env.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end tests for the device-attestation plugin (BUILD.md Part 9
 * step 5). Every test drives the full better-auth handler via
 * `createAuth().handler(...)` so the plugin's hook order relative to
 * origin-check middleware, the bearer plugin, and the magic-link
 * plugin is exercised verbatim — a refactor that accidentally moves
 * the plugin out of the pipeline will fail these immediately.
 */

const MAGIC_LINK_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const SOCIAL_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/social`;
const SIGN_OUT_URL = `http://localhost${AUTH_BASE_PATH}/sign-out`;
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

const extractCode = async (response: Response): Promise<string | undefined> => {
  const text = await response.text();
  if (text.length === 0) {
    return undefined;
  }
  const parsed = errorBodyShape.safeParse(JSON.parse(text));
  return parsed.success ? parsed.data.code : undefined;
};

const socialRequestBody = (nonce: string): unknown => ({
  provider: 'apple',
  idToken: { token: 'not-a-real-jwt', nonce },
});

const defaultJsonHeaders: Record<string, string> = {
  'Content-Type': 'application/json',
  Origin: trustedOrigin,
};

const callAuth = async (
  url: string,
  init: RequestInit,
): Promise<{ response: Response; code: string | undefined }> => {
  const auth = createAuth();
  const response = await auth.handler(new Request(url, init));
  const code = await extractCode(response);
  return { response, code };
};

const post = async (
  url: string,
  body: unknown,
  headers: Record<string, string>,
): Promise<{ response: Response; code: string | undefined }> =>
  await callAuth(url, {
    method: 'POST',
    headers: { ...defaultJsonHeaders, ...headers },
    body: JSON.stringify(body),
  });

const signedPostHeaders = (
  attestation: string,
  extra: Record<string, string> = {},
): Record<string, string> => ({
  [ATTESTATION_HEADER_NAME]: attestation,
  ...extra,
});

const magicLinkReqBinding = (): AttestationBinding => ({
  tag: 'request',
  timestamp: 1_734_489_600n,
});

const magicLinkVerBinding = (token: string): AttestationBinding => ({
  tag: 'verify',
  token,
});

const socialBinding = (rawNonce: string): AttestationBinding => ({
  tag: 'social',
  rawNonce,
});

const signOutBinding = (): AttestationBinding => ({
  tag: 'signOut',
  timestamp: 1n,
});

describe('attestation plugin: header required on every attestation-carrying endpoint', () => {
  test('POST /sign-in/magic-link without x-device-attestation → 401 ATTESTATION_REQUIRED', async () => {
    const { response, code } = await post(MAGIC_LINK_URL, { email: 'x@example.com' }, {});
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_REQUIRED');
  });

  test('GET /magic-link/verify without x-device-attestation → 401 ATTESTATION_REQUIRED', async () => {
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', 'irrelevant');
    const { response, code } = await callAuth(url.toString(), { method: 'GET' });
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_REQUIRED');
  });

  test('POST /sign-in/social without x-device-attestation → 401 ATTESTATION_REQUIRED', async () => {
    const { response, code } = await post(SOCIAL_URL, socialRequestBody('raw'), {});
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_REQUIRED');
  });

  test('POST /sign-out without x-device-attestation → 401 ATTESTATION_REQUIRED', async () => {
    const { response, code } = await callAuth(SIGN_OUT_URL, {
      method: 'POST',
      headers: { ...defaultJsonHeaders },
    });
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_REQUIRED');
  });

  test('empty (all-whitespace) header is treated as missing', async () => {
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'ws@example.com' },
      signedPostHeaders('   '),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_REQUIRED');
  });
});

describe('attestation plugin: structural parse failures return ATTESTATION_INVALID', () => {
  test('garbage base64 rejects with ATTESTATION_INVALID', async () => {
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'garbage@example.com' },
      signedPostHeaders('not@valid-base64!'),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_INVALID');
  });

  test('v !== 3 rejects with ATTESTATION_INVALID before any signature work', async () => {
    const device = createTestDeviceKey();
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: magicLinkReqBinding(),
      overrideVersion: 2,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'oldver@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_INVALID');
  });

  test('bnd payload parse failure (leading-zero timestamp) rejects with ATTESTATION_INVALID', async () => {
    // Hand-build a header whose bnd value has a leading-zero timestamp. The
    // plugin surfaces the AttestationParseError as ATTESTATION_INVALID.
    const fph = Buffer.from(new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xab))
      .toString('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');
    const pk = Buffer.from(new Uint8Array(EC_P256_SPKI_TOTAL_BYTES).fill(0x11)).toString('base64');
    const sig = Buffer.from(
      new Uint8Array([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]),
    ).toString('base64');
    const inner = `{"bnd":"req:01","fph":"${fph}","pk":"${pk}","sig":"${sig}","v":3}`;
    const header = Buffer.from(inner, 'utf8').toString('base64');
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'leading-zero@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_INVALID');
  });
});

describe('attestation plugin: per-tag binding match', () => {
  const bindingMismatches: ReadonlyArray<{
    readonly label: string;
    readonly url: string;
    readonly body: unknown;
    readonly method: 'GET' | 'POST';
    readonly wrongBinding: AttestationBinding;
  }> = [
    {
      label: 'sign-in/magic-link rejects sis: binding',
      url: MAGIC_LINK_URL,
      body: { email: 'wrong-tag-on-magic-link@example.com' },
      method: 'POST',
      wrongBinding: socialBinding('some-nonce'),
    },
    {
      label: 'sign-in/magic-link rejects ver: binding',
      url: MAGIC_LINK_URL,
      body: { email: 'ver-on-magic-link@example.com' },
      method: 'POST',
      wrongBinding: magicLinkVerBinding('some-token'),
    },
    {
      label: 'sign-in/magic-link rejects out: binding',
      url: MAGIC_LINK_URL,
      body: { email: 'out-on-magic-link@example.com' },
      method: 'POST',
      wrongBinding: signOutBinding(),
    },
    {
      label: 'sign-in/social rejects req: binding',
      url: SOCIAL_URL,
      body: socialRequestBody('whatever'),
      method: 'POST',
      wrongBinding: magicLinkReqBinding(),
    },
    {
      label: 'sign-in/social rejects ver: binding',
      url: SOCIAL_URL,
      body: socialRequestBody('whatever'),
      method: 'POST',
      wrongBinding: magicLinkVerBinding('some-token'),
    },
    {
      label: 'sign-in/social rejects out: binding',
      url: SOCIAL_URL,
      body: socialRequestBody('whatever'),
      method: 'POST',
      wrongBinding: signOutBinding(),
    },
    {
      label: 'sign-out rejects sis: binding',
      url: SIGN_OUT_URL,
      body: {},
      method: 'POST',
      wrongBinding: socialBinding('n'),
    },
    {
      label: 'sign-out rejects req: binding',
      url: SIGN_OUT_URL,
      body: {},
      method: 'POST',
      wrongBinding: magicLinkReqBinding(),
    },
  ];

  for (const mismatch of bindingMismatches) {
    test(`${mismatch.label} with 401 ATTESTATION_BINDING_MISMATCH`, async () => {
      const device = createTestDeviceKey();
      const header = buildSignedAttestationHeader({
        deviceKey: device,
        binding: mismatch.wrongBinding,
      });
      const { response, code } = await callAuth(mismatch.url, {
        method: mismatch.method,
        headers: { ...defaultJsonHeaders, [ATTESTATION_HEADER_NAME]: header },
        body: mismatch.method === 'POST' ? JSON.stringify(mismatch.body) : undefined,
      });
      expect(response.status).toBe(401);
      expect(code).toBe('ATTESTATION_BINDING_MISMATCH');
    });
  }

  test('magic-link/verify rejects req: binding with ATTESTATION_BINDING_MISMATCH', async () => {
    const device = createTestDeviceKey();
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: magicLinkReqBinding(),
    });
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', 'placeholder');
    const { response, code } = await callAuth(url.toString(), {
      method: 'GET',
      headers: { [ATTESTATION_HEADER_NAME]: header },
    });
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_BINDING_MISMATCH');
  });
});

describe('attestation plugin: SPKI structural rejection (step 5 crypto floor)', () => {
  test('pk shorter than the 91-byte P-256 SPKI → ATTESTATION_SPKI_INVALID', async () => {
    const device = createTestDeviceKey();
    const short = new Uint8Array(EC_P256_SPKI_TOTAL_BYTES - 1);
    short.set(EC_P256_SPKI_PREFIX.subarray(0, Math.min(EC_P256_SPKI_PREFIX.length, short.length)));
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: magicLinkReqBinding(),
      overridePublicKeySPKI: short,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'short-spki@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_SPKI_INVALID');
  });

  test('pk with wrong curve prefix (RSA-like OID) → ATTESTATION_SPKI_INVALID', async () => {
    const device = createTestDeviceKey();
    // Keep the 91-byte length so only the prefix/tag check rejects.
    const wrong = new Uint8Array(EC_P256_SPKI_TOTAL_BYTES).fill(0x00);
    wrong[0] = 0x30;
    wrong[1] = 0x59;
    // Everything else deliberately zero — prefix compare fails.
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: magicLinkReqBinding(),
      overridePublicKeySPKI: wrong,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'wrong-curve@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_SPKI_INVALID');
  });
});

describe('attestation plugin: ECDSA signature enforcement', () => {
  test('tampered signature → 401 ATTESTATION_SIGNATURE_INVALID', async () => {
    const device = createTestDeviceKey();
    // Build an otherwise-valid attestation, then replace the signature with
    // one that is well-formed DER but does not verify under the pk.
    const fph = new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xab);
    const binding = magicLinkReqBinding();
    const messageBytes = new TextEncoder().encode('not the real signed payload');
    const bogusSignature = Uint8Array.from(
      cryptoSign('sha256', Buffer.from(messageBytes), {
        key: device.privateKey,
        dsaEncoding: 'der',
      }),
    );
    const header = encodeAttestationHeader({
      version: ATTESTATION_VERSION,
      fingerprintHash: fph,
      publicKeySPKI: device.publicKeySPKI,
      binding,
      signature: bogusSignature,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'bad-sig@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('swapped pk (signature made with a different key) → ATTESTATION_SIGNATURE_INVALID', async () => {
    const signer = createTestDeviceKey();
    const impersonator = createTestDeviceKey();
    const header = buildSignedAttestationHeader({
      deviceKey: signer,
      binding: magicLinkReqBinding(),
      overridePublicKeySPKI: impersonator.publicKeySPKI,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'swapped-pk@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('fph-on-wire does not match the fph in the signed message → ATTESTATION_SIGNATURE_INVALID', async () => {
    const device = createTestDeviceKey();
    const wireFph = new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xee);
    const signedFph = new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xab);
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: magicLinkReqBinding(),
      fingerprintHash: signedFph,
      overrideFph: wireFph,
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'fph-mismatch@example.com' },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });
});

describe('attestation plugin: happy-path pass-through', () => {
  const sharedDevice: TestDeviceKey = createTestDeviceKey();

  test('valid req: attestation on /sign-in/magic-link passes the plugin (non-attestation response)', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: sharedDevice,
      binding: magicLinkReqBinding(),
    });
    const { response, code } = await post(
      MAGIC_LINK_URL,
      { email: 'happy-magic-link@example.com' },
      signedPostHeaders(header),
    );
    // Without a delivery adapter wired, the route still succeeds (pinoMagicLinkDelivery logs).
    expect(response.status).toBe(200);
    // No attestation code — the plugin let it through.
    expect(code ?? '').not.toContain('ATTESTATION_');
  });

  test('valid sis: attestation on /sign-in/social passes the plugin; token verify is the next failure', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: sharedDevice,
      binding: socialBinding('happy-nonce'),
    });
    const { response, code } = await post(
      SOCIAL_URL,
      socialRequestBody('happy-nonce'),
      signedPostHeaders(header),
    );
    // Apple verifier rejects the garbage JWT → 401 but NOT an attestation code.
    expect(response.status).toBe(401);
    expect(code ?? '').not.toBe('ATTESTATION_REQUIRED');
    expect(code ?? '').not.toBe('ATTESTATION_INVALID');
    expect(code ?? '').not.toBe('ATTESTATION_BINDING_MISMATCH');
    expect(code ?? '').not.toBe('ATTESTATION_SIGNATURE_INVALID');
    expect(code ?? '').not.toBe('ATTESTATION_SPKI_INVALID');
    expect(code ?? '').not.toBe('ATTESTATION_NONCE_MISMATCH');
    expect(code ?? '').not.toBe('ID_TOKEN_NONCE_REQUIRED');
  });

  test('valid ver: attestation on /magic-link/verify passes the plugin (plugin yields INVALID_TOKEN)', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: sharedDevice,
      binding: magicLinkVerBinding('does-not-exist'),
    });
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', 'does-not-exist');
    const { response, code } = await callAuth(url.toString(), {
      method: 'GET',
      headers: { [ATTESTATION_HEADER_NAME]: header },
    });
    // Plugin yields a redirect carrying ?error=INVALID_TOKEN — status is 3xx,
    // not an attestation 401.
    expect([301, 302, 303, 307, 308]).toContain(response.status);
    expect(code ?? '').not.toContain('ATTESTATION_');
  });

  test('valid out: attestation on /sign-out passes the plugin', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: sharedDevice,
      binding: signOutBinding(),
    });
    const { response, code } = await callAuth(SIGN_OUT_URL, {
      method: 'POST',
      headers: { ...defaultJsonHeaders, [ATTESTATION_HEADER_NAME]: header },
      body: JSON.stringify({}),
    });
    // Without a bearer, sign-out still completes with 200 (no session to kill)
    // — what we need is NOT one of the attestation rejection codes.
    expect(response.status).not.toBe(401);
    expect(code ?? '').not.toContain('ATTESTATION_');
  });
});

describe('attestation plugin: sis: three-way nonce match', () => {
  const device = createTestDeviceKey();

  test('missing body.idToken.nonce → 401 ID_TOKEN_NONCE_REQUIRED', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: socialBinding('raw'),
    });
    const { response, code } = await post(
      SOCIAL_URL,
      { provider: 'apple', idToken: { token: 'x' } },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ID_TOKEN_NONCE_REQUIRED');
  });

  test('mismatched body nonce → 401 ATTESTATION_NONCE_MISMATCH', async () => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: socialBinding('attestation-nonce'),
    });
    const { response, code } = await post(
      SOCIAL_URL,
      { provider: 'apple', idToken: { token: 'x', nonce: 'different' } },
      signedPostHeaders(header),
    );
    expect(response.status).toBe(401);
    expect(code).toBe('ATTESTATION_NONCE_MISMATCH');
  });
});

describe('attestation plugin: scope', () => {
  test('GET /get-session still works without an attestation header', async () => {
    const { response, code } = await callAuth(`http://localhost${AUTH_BASE_PATH}/get-session`, {
      method: 'GET',
    });
    expect(response.status).toBe(200);
    expect(code ?? '').not.toBe('ATTESTATION_REQUIRED');
  });

  test('unknown auth sub-paths do not enable the plugin', async () => {
    // A /ok endpoint-style probe must not trip the attestation gate.
    const { response } = await callAuth(`http://localhost${AUTH_BASE_PATH}/ok`, {
      method: 'GET',
    });
    // We are not asserting on the route itself; the important property is
    // that /ok returns without the plugin intercepting.
    expect(response.status).toBe(200);
  });
});
