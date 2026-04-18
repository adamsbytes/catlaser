import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { magicLinkAttestation, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { ATTESTATION_SKEW_SECONDS } from '~/lib/attestation-skew.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { deriveTokenIdentifier } from '~/lib/magic-link-attestation.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for binding enforcement (skew window + stored-device
 * match on `ver:`).
 *
 * The unit-level skew and binding-parser tests cover the individual
 * primitives; this file drives the full better-auth handler so skew +
 * stored-device-match + the structural crypto floor are exercised in the
 * order a real request visits them.
 *
 * Invariants asserted:
 *
 * 1. `POST /sign-in/magic-link` enforces ±60s skew on the `req:` timestamp.
 * 2. `POST /sign-out` enforces ±60s skew on the `out:` timestamp.
 * 3. The skew window is inclusive — exactly ±60s passes, ±61s rejects.
 * 4. `GET /magic-link/verify` enforces stored-(fph, pk) byte-equal against
 *    whatever was captured at `/sign-in/magic-link` time; either mismatch
 *    produces `DEVICE_MISMATCH` before the magic-link plugin's verify
 *    runs.
 * 5. An absent attestation row (never requested, expired, or previously
 *    consumed) rejects with `DEVICE_MISMATCH`.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const SIGN_OUT_URL = `http://localhost${AUTH_BASE_PATH}/sign-out`;
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';

const errorBodyShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
});

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

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
};

const clearMagicLinkAttestations = async (): Promise<void> => {
  // eslint-disable-next-line drizzle/enforce-delete-with-where -- test-setup helper: per-suite reset of this table is the point
  await db.delete(magicLinkAttestation);
};

const randomEmail = (prefix: string): string => {
  const suffix = randomBytes(6).toString('hex');
  return `${prefix}-${suffix}@example.com`;
};

const extractCode = async (response: Response): Promise<string | undefined> => {
  const text = await response.text();
  if (text.length === 0) {
    return undefined;
  }
  const parsed = errorBodyShape.safeParse(JSON.parse(text));
  return parsed.success ? parsed.data.code : undefined;
};

describe('binding enforcement: req: ±60s skew on /sign-in/magic-link', () => {
  const fixedNow = 1_800_000_000n;
  const nowSeconds: NowSecondsFn = () => fixedNow;
  let device: TestDeviceKey;
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({ magicLinkDelivery: delivery, attestationNowSeconds: nowSeconds });
    device = createTestDeviceKey();
  });

  beforeEach(() => {
    delivery.reset();
  });

  const postSignIn = async (timestamp: bigint, email: string): Promise<Response> => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp },
    });
    return await auth.handler(
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
  };

  test('timestamp exactly at now accepts (delivery fires)', async () => {
    const email = randomEmail('skew-now');
    await clearEmail(email);
    const response = await postSignIn(fixedNow, email);
    expect(response.status).toBe(200);
    expect(delivery.callCount()).toBe(1);
    await clearEmail(email);
  });

  test('timestamp at now + 60s (inclusive upper bound) accepts', async () => {
    const email = randomEmail('skew-plus60');
    await clearEmail(email);
    const response = await postSignIn(fixedNow + ATTESTATION_SKEW_SECONDS, email);
    expect(response.status).toBe(200);
    expect(delivery.callCount()).toBe(1);
    await clearEmail(email);
  });

  test('timestamp at now - 60s (inclusive lower bound) accepts', async () => {
    const email = randomEmail('skew-minus60');
    await clearEmail(email);
    const response = await postSignIn(fixedNow - ATTESTATION_SKEW_SECONDS, email);
    expect(response.status).toBe(200);
    expect(delivery.callCount()).toBe(1);
    await clearEmail(email);
  });

  test('timestamp at now + 61s (past upper bound) rejects; delivery not invoked', async () => {
    const email = randomEmail('skew-plus61');
    await clearEmail(email);
    const response = await postSignIn(fixedNow + ATTESTATION_SKEW_SECONDS + 1n, email);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(delivery.callCount()).toBe(0);
    await clearEmail(email);
  });

  test('timestamp at now - 61s (past lower bound) rejects; delivery not invoked', async () => {
    const email = randomEmail('skew-minus61');
    await clearEmail(email);
    const response = await postSignIn(fixedNow - ATTESTATION_SKEW_SECONDS - 1n, email);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(delivery.callCount()).toBe(0);
    await clearEmail(email);
  });

  test('very-far-past timestamp (captured-attestation replay) rejects', async () => {
    const email = randomEmail('skew-ancient');
    await clearEmail(email);
    const ancient = fixedNow - ATTESTATION_SKEW_SECONDS * 1_000_000n;
    const response = await postSignIn(ancient, email);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(delivery.callCount()).toBe(0);
    await clearEmail(email);
  });

  test('far-future timestamp (clock-skewed or fabricated) rejects', async () => {
    const email = randomEmail('skew-farfuture');
    await clearEmail(email);
    const farFuture = fixedNow + ATTESTATION_SKEW_SECONDS * 1_000_000n;
    const response = await postSignIn(farFuture, email);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(delivery.callCount()).toBe(0);
    await clearEmail(email);
  });
});

describe('binding enforcement: out: ±60s skew on /sign-out', () => {
  const fixedNow = 1_800_000_000n;
  const nowSeconds: NowSecondsFn = () => fixedNow;
  let device: TestDeviceKey;
  let auth: ReturnType<typeof createAuth>;

  beforeAll(() => {
    auth = createAuth({ attestationNowSeconds: nowSeconds });
    device = createTestDeviceKey();
  });

  const postSignOut = async (timestamp: bigint): Promise<Response> => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'signOut', timestamp },
    });
    return await auth.handler(
      new Request(SIGN_OUT_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Origin: trustedOrigin,
          [ATTESTATION_HEADER_NAME]: header,
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({}),
      }),
    );
  };

  test('now + 60s accepts', async () => {
    const response = await postSignOut(fixedNow + ATTESTATION_SKEW_SECONDS);
    // No bearer on this request so sign-out is a no-op; what we care about
    // is NOT getting the attestation skew rejection.
    expect(response.status).not.toBe(401);
  });

  test('now - 60s accepts', async () => {
    const response = await postSignOut(fixedNow - ATTESTATION_SKEW_SECONDS);
    expect(response.status).not.toBe(401);
  });

  test('now + 61s rejects with ATTESTATION_SKEW_EXCEEDED', async () => {
    const response = await postSignOut(fixedNow + ATTESTATION_SKEW_SECONDS + 1n);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('now - 61s rejects with ATTESTATION_SKEW_EXCEEDED', async () => {
    const response = await postSignOut(fixedNow - ATTESTATION_SKEW_SECONDS - 1n);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('ATTESTATION_SKEW_EXCEEDED');
  });
});

describe('binding enforcement: ver: stored (fph, pk) byte-equal on /magic-link/verify', () => {
  const fixedNow = 1_800_000_000n;
  const nowSeconds: NowSecondsFn = () => fixedNow;
  let auth: ReturnType<typeof createAuth>;
  let delivery: RecordingDelivery;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({ magicLinkDelivery: delivery, attestationNowSeconds: nowSeconds });
  });

  beforeEach(async () => {
    delivery.reset();
    await clearMagicLinkAttestations();
  });

  const requestLink = async (email: string, device: TestDeviceKey): Promise<string> => {
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: fixedNow },
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

  const verify = async (token: string, attestation: string): Promise<Response> => {
    const url = new URL(VERIFY_URL_BASE);
    url.searchParams.set('token', token);
    return await auth.handler(
      new Request(url.toString(), {
        method: 'GET',
        headers: { [ATTESTATION_HEADER_NAME]: attestation, ...uniqueClientIpHeader() },
      }),
    );
  };

  test('matching device (same SE key + fph) verifies successfully', async () => {
    const email = randomEmail('ver-match');
    await clearEmail(email);
    const device = createTestDeviceKey();
    const token = await requestLink(email, device);

    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
    });
    const response = await verify(token, verHeader);
    expect(response.status).toBe(200);
    await clearEmail(email);
  });

  test('different device (different SE key) rejects with DEVICE_MISMATCH', async () => {
    const email = randomEmail('ver-diff-sek');
    await clearEmail(email);
    const requesting = createTestDeviceKey();
    const attacker = createTestDeviceKey();
    const token = await requestLink(email, requesting);

    const verHeader = buildSignedAttestationHeader({
      deviceKey: attacker,
      binding: { tag: 'verify', token },
    });
    const response = await verify(token, verHeader);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('DEVICE_MISMATCH');
    await clearEmail(email);
  });

  test('same SE key but different fingerprint hash rejects with DEVICE_MISMATCH', async () => {
    const email = randomEmail('ver-diff-fph');
    await clearEmail(email);
    const device = createTestDeviceKey();
    const token = await requestLink(email, device);

    // Build a verify attestation that signs correctly under the device's
    // key AND carries a fph on the wire matching the signed message — but
    // the fph is a different 32 bytes from what was captured at request
    // time (default is 0xab; override to 0xcd).
    const alteredFph = new Uint8Array(32).fill(0xcd);
    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
      fingerprintHash: alteredFph,
    });
    const response = await verify(token, verHeader);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('DEVICE_MISMATCH');
    await clearEmail(email);
  });

  test('unknown token (no stored row) rejects with DEVICE_MISMATCH', async () => {
    // Build a ver: attestation for a token the server never issued. The
    // signature verifies (crypto floor passes), but the stored-row
    // lookup returns null, so the binding enforcement stage rejects.
    const device = createTestDeviceKey();
    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token: 'never-issued-token-abc' },
    });
    const response = await verify('never-issued-token-abc', verHeader);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('DEVICE_MISMATCH');
  });

  test('expired stored attestation rejects with DEVICE_MISMATCH', async () => {
    const email = randomEmail('ver-expired');
    await clearEmail(email);
    const device = createTestDeviceKey();
    const token = await requestLink(email, device);

    // Forcibly age the stored attestation row past the real wall clock.
    // The magic-link plugin's own verification row still lives (its own
    // 5-min expiry is independent of ours), so a correct device could
    // otherwise satisfy the crypto floor. The stored-device match must
    // still DEVICE_MISMATCH because the stored attestation row has
    // expired — the lookup's expiry check runs against real time, so
    // aging the row to 1 minute ago suffices.
    const staleExpiry = new Date(Date.now() - 60_000);
    await db
      .update(magicLinkAttestation)
      .set({ expiresAt: staleExpiry })
      .where(eq(magicLinkAttestation.tokenIdentifier, deriveTokenIdentifier(token)));

    const verHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'verify', token },
    });
    const response = await verify(token, verHeader);
    expect(response.status).toBe(401);
    expect(await extractCode(response)).toBe('DEVICE_MISMATCH');
    await clearEmail(email);
  });

  test('stored row is written at /sign-in/magic-link time with the expected columns', async () => {
    const email = randomEmail('ver-stored');
    await clearEmail(email);
    const device = createTestDeviceKey();
    const token = await requestLink(email, device);

    const identifier = deriveTokenIdentifier(token);
    const rows = await db
      .select({
        tokenIdentifier: magicLinkAttestation.tokenIdentifier,
        fingerprintHash: magicLinkAttestation.fingerprintHash,
        publicKeySpki: magicLinkAttestation.publicKeySpki,
        expiresAt: magicLinkAttestation.expiresAt,
        createdAt: magicLinkAttestation.createdAt,
      })
      .from(magicLinkAttestation)
      .where(eq(magicLinkAttestation.tokenIdentifier, identifier));
    expect(rows.length).toBe(1);
    const row = rows[0];
    if (row === undefined) {
      throw new Error('expected a stored attestation row');
    }
    expect(row.tokenIdentifier).toBe(identifier);
    expect(row.fingerprintHash.length).toBeGreaterThan(0);
    expect(row.publicKeySpki.length).toBeGreaterThan(0);
    expect(row.expiresAt.getTime()).toBeGreaterThan(row.createdAt.getTime());
    await clearEmail(email);
  });
});
