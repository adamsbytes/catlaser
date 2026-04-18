import { createHash, randomBytes } from 'node:crypto';
import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import type { JWK } from 'jose';
import { SignJWT, exportJWK, generateKeyPair } from 'jose';
import { z } from 'zod';
import { session, sessionAttestation, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { lookupSessionAttestation } from '~/lib/session-attestation.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

const verifyResponseShape = z.object({
  session: z.looseObject({ id: z.string().min(1), userId: z.string().min(1).optional() }),
  user: z.looseObject({ id: z.string().min(1) }),
  token: z.string().min(1),
});

const socialResponseShape = z.object({
  token: z.string().min(1),
  redirect: z.boolean(),
});

/**
 * End-to-end coverage for the per-session SE pubkey capture half of the
 * protected-route contract.
 *
 * Every successful sign-in ceremony must leave a `session_attestation`
 * row whose `(fph, pk)` is byte-identical to what the sign-in request
 * delivered. A regression anywhere in the capture path — missed
 * after-hook, wrong session id, dropped write, cascade mis-wired —
 * renders every subsequent `api:` call unservable. These tests pin the
 * contract end-to-end through the real `createAuth()` handler so the
 * capture cannot be accidentally bypassed by a future plugin reorder.
 *
 * Invariants asserted:
 *
 * 1. `/magic-link/verify` writes the row atomically inside the request.
 * 2. `/sign-in/social` writes the row atomically inside the request.
 * 3. The stored values are the base64-encoded bytes delivered on the
 *    wire — no accidental truncation, no drift from the wire bytes.
 * 4. `ON DELETE CASCADE` removes the row when the owning session goes
 *    away — no stale rows outlive their session.
 */

const APPLE_ISSUER = 'https://appleid.apple.com';
const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const SOCIAL_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/social`;
const [trustedOrigin] = env.TRUSTED_ORIGINS;
if (trustedOrigin === undefined) {
  throw new Error('env.TRUSTED_ORIGINS must contain at least one entry');
}

const encodeBase64Standard = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');
const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeBase64Standard(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

const randomEmail = (prefix: string): string =>
  `${prefix}-${randomBytes(6).toString('hex')}@example.com`;

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      // Cascade: user → session → session_attestation.
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
};

class RecordingDelivery implements MagicLinkDelivery {
  private readonly calls: MagicLinkEmailPayload[] = [];

  // eslint-disable-next-line @typescript-eslint/require-await
  public async send(payload: MagicLinkEmailPayload): Promise<void> {
    this.calls.push(payload);
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

describe('session attestation: captured at /magic-link/verify', () => {
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({ magicLinkDelivery: delivery });
    device = createTestDeviceKey();
  });

  beforeEach(() => {
    delivery.reset();
  });

  const requestLink = async (email: string): Promise<string> => {
    const currentTimestamp = BigInt(Math.floor(Date.now() / 1000));
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: currentTimestamp },
    });
    const response = await auth.handler(
      new Request(SIGN_IN_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: header,
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({ email }),
      }),
    );
    expect(response.status).toBe(200);
    return delivery.latest().token;
  };

  const verifyLink = async (token: string): Promise<{ readonly sessionId: string }> => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
    });
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', token);
    const response = await auth.handler(
      new Request(url.toString(), {
        method: 'GET',
        headers: { [ATTESTATION_HEADER_NAME]: header, ...uniqueClientIpHeader() },
      }),
    );
    expect(response.status).toBe(200);
    const payload = verifyResponseShape.parse(await response.json());
    return { sessionId: payload.session.id };
  };

  test('row is written with byte-identical fph and pk captured on the wire', async () => {
    const email = randomEmail('cap-ml');
    await clearEmail(email);
    const token = await requestLink(email);
    const { sessionId } = await verifyLink(token);

    const stored = await lookupSessionAttestation(sessionId);
    expect(stored).not.toBeNull();
    if (stored === null) {
      throw new Error('missing stored attestation');
    }
    // iOS-defaulted 0xab-filled fingerprint from `defaultFingerprintHash`.
    expect(stored.fingerprintHashB64Url).toBe(encodeBase64UrlNoPad(new Uint8Array(32).fill(0xab)));
    expect(stored.publicKeySpkiB64).toBe(encodeBase64Standard(device.publicKeySPKI));

    await clearEmail(email);
  });

  test('row is bound to exactly one session (unique on session_id)', async () => {
    const email = randomEmail('cap-ml-unique');
    await clearEmail(email);
    const token = await requestLink(email);
    const { sessionId } = await verifyLink(token);

    const rows = await db
      .select({ sessionId: sessionAttestation.sessionId })
      .from(sessionAttestation)
      .where(eq(sessionAttestation.sessionId, sessionId));
    expect(rows.length).toBe(1);
    await clearEmail(email);
  });
});

interface AppleFixture {
  readonly privateKey: CryptoKey;
  readonly publicJwk: JWK;
}

describe('session attestation: captured at /sign-in/social', () => {
  let appleFixture: AppleFixture;
  let device: TestDeviceKey;
  let auth: ReturnType<typeof createAuth>;

  beforeAll(async () => {
    const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
    const publicJwk = await exportJWK(publicKey);
    publicJwk.kid = 'apple-test-kid-session-attestation';
    publicJwk.alg = 'ES256';
    publicJwk.use = 'sig';
    appleFixture = { privateKey, publicJwk };
    device = createTestDeviceKey();
    auth = createAuth({
      // eslint-disable-next-line @typescript-eslint/require-await
      appleFetchJWKS: async () => [appleFixture.publicJwk],
    });
  });

  const signAppleToken = async (rawNonce: string, email: string): Promise<string> => {
    const hashed = createHash('sha256').update(rawNonce).digest('hex');
    const kid = appleFixture.publicJwk.kid ?? 'apple-test-kid-session-attestation';
    return await new SignJWT({
      nonce: hashed,
      email,
      email_verified: true,
    })
      .setProtectedHeader({ alg: 'ES256', kid })
      .setIssuedAt()
      .setExpirationTime('10m')
      .setIssuer(APPLE_ISSUER)
      .setAudience(env.APPLE_APP_BUNDLE_IDENTIFIER)
      .setSubject(`apple-user-${randomBytes(6).toString('hex')}`)
      .sign(appleFixture.privateKey);
  };

  test('social sign-in with a valid Apple token writes the session attestation row', async () => {
    const rawNonce = `session-${randomBytes(6).toString('hex')}`;
    const email = randomEmail('cap-social');
    await clearEmail(email);
    const token = await signAppleToken(rawNonce, email);
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: {
        tag: 'social',
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        rawNonce,
      },
    });

    const response = await auth.handler(
      new Request(SOCIAL_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: header,
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({
          provider: 'apple',
          idToken: { token, nonce: rawNonce },
        }),
      }),
    );
    expect(response.status).toBe(200);
    const payload = socialResponseShape.parse(await response.json());
    expect(payload.token.length).toBeGreaterThan(0);

    // Resolve the newly-created session via the user row the sign-in
    // created. Filtering by email gives a deterministic 1:1 join from
    // the randomised test email to the session row, without relying on
    // the ordering of a full-table select.
    const userRows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
    const userRow = userRows[0];
    if (userRow === undefined) {
      throw new Error('no user row found for social sign-in');
    }
    const sessionRows = await db
      .select({ id: session.id })
      .from(session)
      .where(eq(session.userId, userRow.id));
    const sessionRow = sessionRows[0];
    if (sessionRow === undefined) {
      throw new Error('no session row found for social sign-in');
    }
    const stored = await lookupSessionAttestation(sessionRow.id);
    expect(stored).not.toBeNull();
    if (stored === null) {
      throw new Error('missing stored attestation for social sign-in');
    }
    expect(stored.publicKeySpkiB64).toBe(encodeBase64Standard(device.publicKeySPKI));
    expect(stored.fingerprintHashB64Url).toBe(encodeBase64UrlNoPad(new Uint8Array(32).fill(0xab)));

    await clearEmail(email);
  });
});

describe('session attestation: cascade lifecycle', () => {
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({ magicLinkDelivery: delivery });
    device = createTestDeviceKey();
  });

  beforeEach(() => {
    delivery.reset();
  });

  test('deleting the session cascades the session_attestation row', async () => {
    const email = randomEmail('cascade-session');
    await clearEmail(email);

    const currentTimestamp = BigInt(Math.floor(Date.now() / 1000));
    const reqHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: currentTimestamp },
    });
    const signInResponse = await auth.handler(
      new Request(SIGN_IN_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: reqHeader,
        },
        body: JSON.stringify({ email }),
      }),
    );
    expect(signInResponse.status).toBe(200);
    const { token } = delivery.latest();

    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
    });
    const verifyUrl = new URL(VERIFY_URL_BASE);
    verifyUrl.searchParams.set('token', token);
    const verifyResponse = await auth.handler(
      new Request(verifyUrl.toString(), {
        method: 'GET',
        headers: { [ATTESTATION_HEADER_NAME]: verHeader, ...uniqueClientIpHeader() },
      }),
    );
    expect(verifyResponse.status).toBe(200);
    const verifyBody = verifyResponseShape.parse(await verifyResponse.json());
    const sessionId = verifyBody.session.id;

    expect(await lookupSessionAttestation(sessionId)).not.toBeNull();

    await db.delete(session).where(eq(session.id, sessionId));

    expect(await lookupSessionAttestation(sessionId)).toBeNull();

    await clearEmail(email);
  });

  test('deleting the owning user cascades through session to session_attestation', async () => {
    const email = randomEmail('cascade-user');
    await clearEmail(email);

    const currentTimestamp = BigInt(Math.floor(Date.now() / 1000));
    const reqHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: currentTimestamp },
    });
    const signInResponse = await auth.handler(
      new Request(SIGN_IN_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: reqHeader,
        },
        body: JSON.stringify({ email }),
      }),
    );
    expect(signInResponse.status).toBe(200);
    const { token } = delivery.latest();

    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
    });
    const verifyUrl = new URL(VERIFY_URL_BASE);
    verifyUrl.searchParams.set('token', token);
    const verifyResponse = await auth.handler(
      new Request(verifyUrl.toString(), {
        method: 'GET',
        headers: { [ATTESTATION_HEADER_NAME]: verHeader, ...uniqueClientIpHeader() },
      }),
    );
    expect(verifyResponse.status).toBe(200);
    const verifyBody = verifyResponseShape.parse(await verifyResponse.json());
    const sessionId = verifyBody.session.id;

    expect(await lookupSessionAttestation(sessionId)).not.toBeNull();

    // Cascade through the user → session foreign key.
    await clearEmail(email);

    expect(await lookupSessionAttestation(sessionId)).toBeNull();
  });
});
