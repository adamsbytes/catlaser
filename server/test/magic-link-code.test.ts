import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { magicLinkCode, user, verification } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import { deriveCodeIdentifier, MAGIC_LINK_CODE_MAX_ATTEMPTS } from '~/lib/magic-link-code.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for `POST /magic-link/verify-by-code` — the
 * backup-code sibling of `GET /magic-link/verify`.
 *
 * Invariants exercised:
 *
 *  1. A correct code submitted by the original device completes sign-in
 *     with the same response shape as the URL path (bearer + session).
 *  2. The wrong device gets `DEVICE_MISMATCH` even with the correct
 *     code — the stored `(fph, pk)` byte-match is load-bearing.
 *  3. Attempt counter decrements on every miss; after
 *     `MAGIC_LINK_CODE_MAX_ATTEMPTS` misses the row is gone and the
 *     code is permanently invalid.
 *  4. A correct code cannot be redeemed twice — the `magic_link_code`
 *     row and the underlying `verification` row are both deleted.
 *  5. URL path and code path are mutually exclusive: consuming one
 *     invalidates the other via shared `token_identifier`.
 *  6. Malformed codes reject at the Zod body layer.
 *  7. Missing / malformed attestation headers reject at the
 *     attestation-plugin before-hook, never reaching the endpoint.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_BY_CODE_URL = `http://localhost${AUTH_BASE_PATH}/magic-link/verify-by-code`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const [trustedOrigin] = env.TRUSTED_ORIGINS;
if (trustedOrigin === undefined) {
  throw new Error('env.TRUSTED_ORIGINS must contain at least one entry');
}

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

const verifyBodyShape = z.object({
  token: z.string().min(1),
  user: z.looseObject({ id: z.string().min(1), email: z.string().optional() }),
  session: z.looseObject({ id: z.string().min(1) }),
});

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
};

/**
 * Recording delivery that captures every payload (URL + code) for
 * later assertion. The suite reads the most recently-captured code to
 * exercise the verify-by-code path end-to-end.
 */
class RecordingDelivery implements MagicLinkDelivery {
  private readonly calls: MagicLinkEmailPayload[] = [];

  // eslint-disable-next-line @typescript-eslint/require-await
  public async send(payload: MagicLinkEmailPayload): Promise<void> {
    this.calls.push(payload);
  }

  public callCount(): number {
    return this.calls.length;
  }

  public latest(): MagicLinkEmailPayload {
    const last = this.calls.at(-1);
    if (last === undefined) {
      throw new Error('RecordingDelivery had no calls');
    }
    return last;
  }

  public reset(): void {
    this.calls.length = 0;
  }
}

let delivery: RecordingDelivery;
let auth: ReturnType<typeof createAuth>;
let deviceKey: TestDeviceKey;
let attackerKey: TestDeviceKey;

const currentUnixSeconds = (): bigint => BigInt(Math.floor(Date.now() / 1000));

const reqAttestation = (device: TestDeviceKey = deviceKey): string =>
  buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'request', timestamp: currentUnixSeconds() },
  });

const codeAttestation = (code: string, device: TestDeviceKey = deviceKey): string =>
  buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'verify', token: code },
  });

/** Request a magic link; returns the captured payload. */
const requestMagicLink = async (email: string): Promise<MagicLinkEmailPayload> => {
  delivery.reset();
  const response = await auth.handler(
    new Request(SIGN_IN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: trustedOrigin,
        [ATTESTATION_HEADER_NAME]: reqAttestation(),
        ...uniqueClientIpHeader(),
      },
      body: JSON.stringify({ email }),
    }),
  );
  expect(response.status).toBe(200);
  expect(delivery.callCount()).toBe(1);
  return delivery.latest();
};

interface CodeVerifyOptions {
  readonly attestation?: string;
  readonly skipAttestation?: boolean;
}

const verifyByCode = async (
  code: string,
  options: CodeVerifyOptions = {},
): Promise<{ response: Response; body: unknown }> => {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Origin: trustedOrigin,
    ...uniqueClientIpHeader(),
  };
  if (options.skipAttestation !== true) {
    headers[ATTESTATION_HEADER_NAME] = options.attestation ?? codeAttestation(code);
  }
  const response = await auth.handler(
    new Request(VERIFY_BY_CODE_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ code }),
    }),
  );
  const text = await response.text();
  const body: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { response, body };
};

const verifyByUrl = async (token: string): Promise<Response> => {
  const url = new URL(VERIFY_URL_BASE);
  url.searchParams.set('token', token);
  const headers: Record<string, string> = {
    [ATTESTATION_HEADER_NAME]: buildSignedAttestationHeader({
      deviceKey,
      binding: { tag: 'verify', token },
    }),
    ...uniqueClientIpHeader(),
  };
  return await auth.handler(new Request(url.toString(), { method: 'GET', headers }));
};

beforeAll(() => {
  delivery = new RecordingDelivery();
  auth = createAuth({ magicLinkDelivery: delivery });
  deviceKey = createTestDeviceKey();
  attackerKey = createTestDeviceKey();
});

beforeEach(() => {
  delivery.reset();
});

describe('verify-by-code: emailed payload shape', () => {
  test('every magic-link request returns a 6-digit numeric code', async () => {
    const email = 'code-shape@example.com';
    const payload = await requestMagicLink(email);
    expect(payload.code).toMatch(/^\d{6}$/v);
    await clearEmail(email);
  });

  test('code and token are persisted as distinct rows but share token_identifier', async () => {
    const email = 'code-link@example.com';
    const payload = await requestMagicLink(email);
    const codeIdentifier = deriveCodeIdentifier(payload.code, env.BETTER_AUTH_SECRET);
    const rows = await db
      .select({
        tokenIdentifier: magicLinkCode.tokenIdentifier,
        attemptsRemaining: magicLinkCode.attemptsRemaining,
      })
      .from(magicLinkCode)
      .where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
    expect(rows).toHaveLength(1);
    expect(rows[0]?.attemptsRemaining).toBe(MAGIC_LINK_CODE_MAX_ATTEMPTS);
    await clearEmail(email);
  });
});

describe('verify-by-code: happy path', () => {
  test('correct code from requesting device mints a session', async () => {
    const email = 'code-happy@example.com';
    const payload = await requestMagicLink(email);
    const { response, body } = await verifyByCode(payload.code);
    expect(response.status).toBe(200);
    const parsed = verifyBodyShape.parse(body);
    expect(parsed.user.email).toBe(email);
    expect(response.headers.get('set-auth-token')).not.toBeNull();
    await clearEmail(email);
  });

  test('successful redeem deletes the magic_link_code row', async () => {
    const email = 'code-deletes-row@example.com';
    const payload = await requestMagicLink(email);
    const codeIdentifier = deriveCodeIdentifier(payload.code, env.BETTER_AUTH_SECRET);
    const { response } = await verifyByCode(payload.code);
    expect(response.status).toBe(200);
    const rows = await db
      .select({ id: magicLinkCode.id })
      .from(magicLinkCode)
      .where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
    expect(rows).toHaveLength(0);
    await clearEmail(email);
  });

  test('a used code cannot be redeemed a second time', async () => {
    const email = 'code-single-use@example.com';
    const payload = await requestMagicLink(email);
    const first = await verifyByCode(payload.code);
    expect(first.response.status).toBe(200);
    const second = await verifyByCode(payload.code);
    expect(second.response.status).toBe(401);
    expect(errorBodyShape.parse(second.body).code).toBe('INVALID_CODE');
    await clearEmail(email);
  });

  // The iOS client normalises whitespace and hyphens BEFORE signing, so
  // the attestation binding always carries 6 digits. A defence-in-depth
  // normalisation lives server-side in `isPlausibleBackupCode` in case a
  // non-iOS client ever submits `"123 456"` in the body; we intentionally
  // do not cover that path here because the attestation plugin rejects
  // whitespace inside `ver:<bnd>` at parse time — any client that signs
  // `ver:123 456` never reaches the endpoint, so the test would exercise
  // the attestation-plugin rejection rather than the body normaliser.
});

describe('verify-by-code: device-mismatch', () => {
  test('attacker key with correct code → DEVICE_MISMATCH', async () => {
    const email = 'code-wrong-device@example.com';
    const payload = await requestMagicLink(email);
    const { response, body } = await verifyByCode(payload.code, {
      attestation: codeAttestation(payload.code, attackerKey),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('DEVICE_MISMATCH');
    await clearEmail(email);
  });

  test('a failed attempt decrements attempts_remaining but does not consume the row', async () => {
    const email = 'code-decrement@example.com';
    const payload = await requestMagicLink(email);
    await verifyByCode(payload.code, {
      attestation: codeAttestation(payload.code, attackerKey),
    });
    const codeIdentifier = deriveCodeIdentifier(payload.code, env.BETTER_AUTH_SECRET);
    const rows = await db
      .select({ attemptsRemaining: magicLinkCode.attemptsRemaining })
      .from(magicLinkCode)
      .where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
    expect(rows[0]?.attemptsRemaining).toBe(MAGIC_LINK_CODE_MAX_ATTEMPTS - 1);
    // After the misses, the real device can still redeem.
    const ok = await verifyByCode(payload.code);
    expect(ok.response.status).toBe(200);
    await clearEmail(email);
  });

  test('exhausting attempts deletes the row; further attempts become INVALID_CODE', async () => {
    const email = 'code-exhausted@example.com';
    const payload = await requestMagicLink(email);
    const attestation = codeAttestation(payload.code, attackerKey);
    // Sequential: each attempt's row mutation must land before the next
    // looks up the row. eslint's `no-await-in-loop` flags this, but
    // batching via Promise.all would add no value because the server-
    // side FOR UPDATE lock already serialises the txns — we'd just
    // send N concurrent requests that each wait on the lock anyway.
    for (let i = 0; i < MAGIC_LINK_CODE_MAX_ATTEMPTS; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const { response, body } = await verifyByCode(payload.code, { attestation });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).code).toBe('DEVICE_MISMATCH');
    }
    // Correct device now gets INVALID_CODE because the row is gone.
    const after = await verifyByCode(payload.code);
    expect(after.response.status).toBe(401);
    expect(errorBodyShape.parse(after.body).code).toBe('INVALID_CODE');
    await clearEmail(email);
  });
});

describe('verify-by-code: cross-path mutual exclusion', () => {
  test('URL-path verify invalidates the sibling code row', async () => {
    const email = 'code-url-first@example.com';
    const payload = await requestMagicLink(email);
    const urlResponse = await verifyByUrl(payload.token);
    expect(urlResponse.status).toBe(200);
    const { response, body } = await verifyByCode(payload.code);
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('INVALID_CODE');
    await clearEmail(email);
  });

  test('code-path verify invalidates the URL token', async () => {
    const email = 'code-first@example.com';
    const payload = await requestMagicLink(email);
    const codeResponse = await verifyByCode(payload.code);
    expect(codeResponse.response.status).toBe(200);
    const urlResponse = await verifyByUrl(payload.token);
    // Better-auth's URL path redirects on unknown token to the
    // errorCallbackURL; the status is a redirect, not 200. The key
    // assertion is that a second session is NOT minted — we check
    // that no `set-auth-token` header comes back.
    expect(urlResponse.headers.get('set-auth-token')).toBeNull();
    await clearEmail(email);
  });
});

describe('verify-by-code: body validation', () => {
  test('missing code → 400', async () => {
    const response = await auth.handler(
      new Request(VERIFY_BY_CODE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: codeAttestation('123456'),
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({}),
      }),
    );
    expect(response.status).toBe(400);
  });

  test('non-numeric code → 400', async () => {
    const response = await auth.handler(
      new Request(VERIFY_BY_CODE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: codeAttestation('abcdef'),
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({ code: 'abcdef' }),
      }),
    );
    expect(response.status).toBe(400);
  });

  test('too-short code → 400', async () => {
    const response = await auth.handler(
      new Request(VERIFY_BY_CODE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: codeAttestation('12345'),
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({ code: '12345' }),
      }),
    );
    expect(response.status).toBe(400);
  });
});

describe('verify-by-code: attestation enforcement', () => {
  test('missing attestation → 401 ATTESTATION_REQUIRED', async () => {
    const { response, body } = await verifyByCode('123456', { skipAttestation: true });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_REQUIRED');
  });

  test('wrong binding tag (api: instead of ver:) → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const api = buildSignedAttestationHeader({
      deviceKey,
      binding: { tag: 'api', timestamp: currentUnixSeconds() },
    });
    const { response, body } = await verifyByCode('123456', { attestation: api });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('captured ver:<token> attestation replayed against verify-by-code fails', async () => {
    // A ver:<token> header signed under the requesting device's key
    // is a legitimate attestation for the URL path. Replaying it
    // against verify-by-code (with a body code that happens to match
    // the same stored row by coincidence) must still be rejected —
    // the binding tag check + the code body's distinct HMAC space
    // make this structurally impossible, but asserting it here pins
    // the invariant against future refactors.
    const email = 'code-captured-ver@example.com';
    const payload = await requestMagicLink(email);
    const verTokenAttestation = buildSignedAttestationHeader({
      deviceKey,
      binding: { tag: 'verify', token: payload.token },
    });
    const { response, body } = await verifyByCode(payload.code, {
      attestation: verTokenAttestation,
    });
    // The binding tag IS 'verify' so the tag check passes — what
    // fails is the stored-device byte-match: the attestation was
    // signed over `ver:<token>` but the code HMAC lookup hits a
    // row whose stored (fph, pk) match the requesting device. The
    // fph/pk themselves would match, but the signature on the
    // attestation header is over the wrong message bytes. The
    // attestation plugin's signature verify therefore fails.
    expect(response.status).toBe(401);
    const parsed = errorBodyShape.parse(body);
    // Either the signature fails to verify under the wire fph||bnd
    // (most likely given the signed-message is over `ver:<token>`
    // but the endpoint expects `ver:<code>`) OR the body code does
    // not resolve. Either outcome rejects sign-in — assert a 401
    // and leave the exact error code to the signature/binding
    // layer, since this is a defense-in-depth check.
    expect(parsed.code).not.toBeUndefined();
    // `ATTESTATION_BINDING_MISMATCH` is the enforcement we expect: the
    // attestation signs `ver:<URL-token>` but the body code does not
    // match. The other codes are tolerated here because a future
    // refactor that relies on a different structural layer (signature,
    // device match, code lookup) would still reject this replay.
    expect([
      'ATTESTATION_BINDING_MISMATCH',
      'ATTESTATION_SIGNATURE_INVALID',
      'INVALID_CODE',
      'DEVICE_MISMATCH',
    ]).toContain(parsed.code ?? '');
    await clearEmail(email);
  });
});

describe('verify-by-code: unknown code', () => {
  test('six digits not matching any row → 401 INVALID_CODE', async () => {
    // No request has been issued in this test; there is no row for
    // this code identifier. The attestation parses and verifies —
    // the rejection comes from `consumeMagicLinkCode` returning
    // `not-found`.
    const code = '000000';
    const { response, body } = await verifyByCode(code);
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('INVALID_CODE');
  });
});

describe('verify-by-code: database side-effects', () => {
  test('success consumes the verification row', async () => {
    const email = 'code-consumes-verification@example.com';
    const payload = await requestMagicLink(email);
    const before = await db.select({ id: verification.id }).from(verification);
    expect(before.length).toBeGreaterThanOrEqual(1);
    await verifyByCode(payload.code);
    const stillThere = await db
      .select({ id: verification.id })
      .from(verification)
      .where(and(eq(verification.id, before.at(-1)?.id ?? '')));
    expect(stillThere).toHaveLength(0);
    await clearEmail(email);
  });
});
