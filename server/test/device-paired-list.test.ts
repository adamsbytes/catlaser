import { randomBytes } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { devicePairingCode, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { hashPairingCode, issuePairingCode } from '~/lib/device-pairing.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import {
  DEVICES_PAIR_PATH,
  DEVICES_PAIRED_PATH,
  buildDevicesPairRoute,
  buildDevicesPairedRoute,
} from '~/routes/devices.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the ownership-re-verification endpoint,
 * `GET /api/v1/devices/paired`, and for the supersession invariant
 * `exchangePairingCode` now enforces (a new claim against the same
 * device_id atomically revokes prior active claims).
 *
 * Invariants under test:
 *
 * 1. The list response enumerates exactly the rows owned by the
 *    signed-in user with `claimed_at IS NOT NULL AND revoked_at IS
 *    NULL`. Rows not claimed yet, rows owned by a different user, and
 *    rows that were revoked by a subsequent re-pair all disappear from
 *    the response.
 * 2. The list response is ordered most-recent-claim-first so the app's
 *    UI can render the primary device without an extra sort.
 * 3. Re-pair of the same physical device by a *different* user
 *    atomically revokes the original owner's claim. The original owner
 *    sees an empty list after the supersession; the new owner sees the
 *    single active claim. This is the core guarantee the iOS
 *    `PairingViewModel` relies on for its launch-time re-check.
 * 4. The attestation gate still runs: a call with no bearer, a call
 *    with an `api:` signature outside the skew window, and a call with
 *    the wrong binding tag are all rejected before any query fires.
 */

const SIGN_IN_URL = `https://auth.catlaser.example${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `https://auth.catlaser.example${AUTH_BASE_PATH}/magic-link/verify`;
const PAIR_URL = `https://auth.catlaser.example${DEVICES_PAIR_PATH}`;
const PAIRED_URL = `https://auth.catlaser.example${DEVICES_PAIRED_PATH}`;
const [trustedOrigin] = env.TRUSTED_ORIGINS;
if (trustedOrigin === undefined) {
  // Zod already enforces `.min(1)` on parse, so this branch is the TS
  // narrowing hatch — not a runtime safety net. Crash loudly if it
  // somehow fires; a "sensible default" here would silently mask a
  // broken env and let magic-link / sign-in tests pass against the
  // wrong origin.
  throw new Error('env.TRUSTED_ORIGINS must contain at least one entry');
}

const listResponseShape = z.object({
  ok: z.literal(true),
  data: z.object({
    devices: z.array(
      z.object({
        device_id: z.string().min(1),
        device_name: z.string().nullable(),
        host: z.string().min(1),
        port: z.number().int().positive(),
        paired_at: z.string().min(1),
      }),
    ),
  }),
});

const errorBodyShape = z.object({
  ok: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
});

const verifyResponseShape = z.object({
  session: z.looseObject({ id: z.string().min(1) }),
  user: z.looseObject({ id: z.string().min(1) }),
  token: z.string().min(1),
});

const randomEmail = (prefix: string): string =>
  `${prefix}-${randomBytes(6).toString('hex')}@example.com`;

const randomPairingCode = (): string => {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const buf = randomBytes(32);
  let out = '';
  for (const byte of buf) {
    const char = alphabet[byte % 32];
    if (char === undefined) {
      throw new Error('unreachable: alphabet index out of range');
    }
    out += char;
  }
  return out;
};

const randomDeviceId = (): string => `cat-${randomBytes(4).toString('hex')}`;

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
};

const clearCodeHash = async (codeHash: string): Promise<void> => {
  await db.delete(devicePairingCode).where(eq(devicePairingCode.codeHash, codeHash));
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

interface MutableClock {
  readonly now: NowSecondsFn;
  set: (value: bigint) => void;
}
const mutableClock = (initial: bigint): MutableClock => {
  let current = initial;
  return {
    now: () => current,
    set: (value) => {
      current = value;
    },
  };
};

interface SignedInFixture {
  readonly email: string;
  readonly bearer: string;
  readonly sessionId: string;
  readonly userId: string;
  readonly device: TestDeviceKey;
}

/**
 * Sign in a fresh user and return its bearer + SE key material. Each
 * user owns its own P-256 keypair so cross-user supersession tests
 * can't accidentally verify against the wrong `session_attestation`.
 */
const signIn = async (
  auth: ReturnType<typeof createAuth>,
  delivery: RecordingDelivery,
  clockNow: bigint,
  emailPrefix: string,
): Promise<SignedInFixture> => {
  const email = randomEmail(emailPrefix);
  await clearEmail(email);
  delivery.reset();
  const device = createTestDeviceKey();

  const reqHeader = buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'request', timestamp: clockNow },
  });
  const signInResponse = await auth.handler(
    new Request(SIGN_IN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: trustedOrigin,
        [ATTESTATION_HEADER_NAME]: reqHeader,
        ...uniqueClientIpHeader(),
      },
      body: JSON.stringify({ email }),
    }),
  );
  if (signInResponse.status !== 200) {
    throw new Error(`sign-in failed: ${signInResponse.status.toString()}`);
  }
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
  if (verifyResponse.status !== 200) {
    throw new Error(`verify failed: ${verifyResponse.status.toString()}`);
  }
  const verifyPayload = verifyResponseShape.parse(await verifyResponse.json());
  const bearer = verifyResponse.headers.get('set-auth-token');
  if (bearer === null || bearer.length === 0) {
    throw new Error('expected set-auth-token header on verify response');
  }
  return {
    email,
    bearer,
    sessionId: verifyPayload.session.id,
    userId: verifyPayload.user.id,
    device,
  };
};

describe('GET /api/v1/devices/paired', () => {
  const fixedNow = 1_810_200_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let alice: SignedInFixture;
  let bob: SignedInFixture;
  let pair: (request: Request) => Promise<Response>;
  let list: (request: Request) => Promise<Response>;
  const seededHashes: string[] = [];

  const apiHeader = (device: TestDeviceKey, ts: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: ts },
    });

  const listAs = async (fixture: SignedInFixture): Promise<Response> =>
    await list(
      new Request(PAIRED_URL, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${fixture.bearer}`,
          [ATTESTATION_HEADER_NAME]: apiHeader(fixture.device),
          ...uniqueClientIpHeader(),
        },
      }),
    );

  const pairAs = async (
    fixture: SignedInFixture,
    input: { readonly code: string; readonly deviceId: string },
  ): Promise<Response> =>
    await pair(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${fixture.bearer}`,
          [ATTESTATION_HEADER_NAME]: apiHeader(fixture.device),
          'Idempotency-Key': crypto.randomUUID(),
          ...uniqueClientIpHeader(),
        },
        body: JSON.stringify({ code: input.code, device_id: input.deviceId }),
      }),
    );

  const seedIssuance = async (
    overrides: Partial<{
      code: string;
      deviceId: string;
      deviceName: string;
      host: string;
      port: number;
    }> = {},
  ): Promise<{ readonly code: string; readonly deviceId: string }> => {
    const code = overrides.code ?? randomPairingCode();
    const deviceId = overrides.deviceId ?? randomDeviceId();
    const { codeHash } = await issuePairingCode({
      code,
      deviceId,
      tailscaleHost: overrides.host ?? '100.64.0.42',
      tailscalePort: overrides.port ?? 9820,
      ...(overrides.deviceName === undefined ? {} : { deviceName: overrides.deviceName }),
    });
    seededHashes.push(codeHash);
    return { code, deviceId };
  };

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    list = buildDevicesPairedRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    alice = await signIn(auth, delivery, fixedNow, 'alice');
    bob = await signIn(auth, delivery, fixedNow, 'bob');
  });

  afterAll(async () => {
    await clearEmail(alice.email);
    await clearEmail(bob.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  afterEach(async () => {
    const hashes = seededHashes.splice(0);
    await Promise.all(hashes.map(async (h) => await clearCodeHash(h)));
  });

  test('empty list before any pairing', async () => {
    const response = await listAs(alice);
    expect(response.status).toBe(200);
    const body = listResponseShape.parse(await response.json());
    expect(body.data.devices).toHaveLength(0);
  });

  test('single pair shows up on the claimant with endpoint details', async () => {
    const { code, deviceId } = await seedIssuance({
      deviceName: 'Living Room',
      host: '100.64.0.42',
      port: 9820,
    });
    const claimResponse = await pairAs(alice, { code, deviceId });
    expect(claimResponse.status).toBe(200);

    const listResponse = await listAs(alice);
    expect(listResponse.status).toBe(200);
    const body = listResponseShape.parse(await listResponse.json());
    expect(body.data.devices).toHaveLength(1);
    const [device] = body.data.devices;
    if (device === undefined) {
      throw new Error('expected one device');
    }
    expect(device.device_id).toBe(deviceId);
    expect(device.device_name).toBe('Living Room');
    expect(device.host).toBe('100.64.0.42');
    expect(device.port).toBe(9820);
    expect(typeof device.paired_at).toBe('string');
    expect(Date.parse(device.paired_at)).not.toBeNaN();
  });

  test("a different user sees an empty list for another user's pairing", async () => {
    const { code, deviceId } = await seedIssuance();
    const claim = await pairAs(alice, { code, deviceId });
    expect(claim.status).toBe(200);

    const response = await listAs(bob);
    expect(response.status).toBe(200);
    const body = listResponseShape.parse(await response.json());
    expect(body.data.devices).toHaveLength(0);
  });

  test('re-pair of the same device_id by another user revokes the prior claim', async () => {
    // Alice pairs. Then the device is re-provisioned (fresh code) and
    // Bob pairs. Alice's list must become empty; Bob's must show the
    // device. This is the core ownership-re-verification invariant.
    const { code: codeA, deviceId } = await seedIssuance({ deviceName: 'Shared' });
    const codeAHash = hashPairingCode(codeA);
    await pairAs(alice, { code: codeA, deviceId });

    const codeB = randomPairingCode();
    const { codeHash: codeBHash } = await issuePairingCode({
      code: codeB,
      deviceId,
      tailscaleHost: '100.64.0.43',
      tailscalePort: 9820,
    });
    seededHashes.push(codeBHash);
    await pairAs(bob, { code: codeB, deviceId });

    const aliceResponse = await listAs(alice);
    const aliceList = listResponseShape.parse(await aliceResponse.json());
    expect(aliceList.data.devices).toHaveLength(0);

    const bobResponse = await listAs(bob);
    const bobList = listResponseShape.parse(await bobResponse.json());
    expect(bobList.data.devices).toHaveLength(1);
    const [device] = bobList.data.devices;
    if (device === undefined) {
      throw new Error('expected one device for bob');
    }
    expect(device.device_id).toBe(deviceId);
    expect(device.host).toBe('100.64.0.43');

    // The historical row survives for fleet audit — it's the DB-level
    // `revoked_at` that hides it from the list response.
    const aliceHistory = await db
      .select({
        claimedBy: devicePairingCode.claimedByUserId,
        revokedAt: devicePairingCode.revokedAt,
      })
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, codeAHash));
    expect(aliceHistory).toHaveLength(1);
    const [aliceRow] = aliceHistory;
    if (aliceRow === undefined) {
      throw new Error('expected alice row to survive');
    }
    expect(aliceRow.claimedBy).toBe(alice.userId);
    expect(aliceRow.revokedAt).not.toBeNull();
  });

  test('re-pair of the same device_id by the SAME user keeps exactly one active row', async () => {
    // Alice re-pairs her own device (fresh QR). The old row is
    // superseded; the new row is active. The list still shows one
    // device but with the new endpoint.
    const { code: codeA, deviceId } = await seedIssuance({ host: '100.64.1.10' });
    await pairAs(alice, { code: codeA, deviceId });

    const codeB = randomPairingCode();
    const { codeHash: codeBHash } = await issuePairingCode({
      code: codeB,
      deviceId,
      tailscaleHost: '100.64.1.11',
      tailscalePort: 9820,
    });
    seededHashes.push(codeBHash);
    await pairAs(alice, { code: codeB, deviceId });

    const aliceHttp = await listAs(alice);
    const response = listResponseShape.parse(await aliceHttp.json());
    expect(response.data.devices).toHaveLength(1);
    const [device] = response.data.devices;
    if (device === undefined) {
      throw new Error('expected exactly one active device');
    }
    expect(device.device_id).toBe(deviceId);
    expect(device.host).toBe('100.64.1.11');
  });

  test('list is ordered most-recent-claim-first', async () => {
    const { code: codeA, deviceId: idA } = await seedIssuance();
    const { code: codeB, deviceId: idB } = await seedIssuance();

    clock.set(fixedNow);
    await pairAs(alice, { code: codeA, deviceId: idA });
    // Bump the clock to give the second claim a later timestamp.
    clock.set(fixedNow + 5n);
    await pairAs(alice, { code: codeB, deviceId: idB });

    const aliceHttp = await listAs(alice);
    const response = listResponseShape.parse(await aliceHttp.json());
    expect(response.data.devices.map((d) => d.device_id)).toEqual([idB, idA]);
  });

  test('unclaimed issuance does not appear', async () => {
    await seedIssuance();
    const aliceHttp = await listAs(alice);
    const response = listResponseShape.parse(await aliceHttp.json());
    expect(response.data.devices).toHaveLength(0);
  });

  test('missing bearer → 401 SESSION_REQUIRED', async () => {
    const response = await list(
      new Request(PAIRED_URL, {
        method: 'GET',
        headers: {
          [ATTESTATION_HEADER_NAME]: apiHeader(alice.device),
          ...uniqueClientIpHeader(),
        },
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('SESSION_REQUIRED');
  });

  test('missing attestation → 401 ATTESTATION_REQUIRED', async () => {
    const response = await list(
      new Request(PAIRED_URL, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${alice.bearer}`,
          ...uniqueClientIpHeader(),
        },
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('ATTESTATION_REQUIRED');
  });

  test('wrong binding tag → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    // A `req:` header is legitimate for sign-in but MUST NOT satisfy a
    // protected-route call. The gate rejects every tag except `api:`.
    const wrongTagHeader = buildSignedAttestationHeader({
      deviceKey: alice.device,
      binding: { tag: 'request', timestamp: fixedNow },
    });
    const response = await list(
      new Request(PAIRED_URL, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${alice.bearer}`,
          [ATTESTATION_HEADER_NAME]: wrongTagHeader,
          ...uniqueClientIpHeader(),
        },
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('stale attestation (past the ±60s skew) → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
    const stale = buildSignedAttestationHeader({
      deviceKey: alice.device,
      binding: { tag: 'api', timestamp: fixedNow - 120n },
    });
    const response = await list(
      new Request(PAIRED_URL, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${alice.bearer}`,
          [ATTESTATION_HEADER_NAME]: stale,
          ...uniqueClientIpHeader(),
        },
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('wrong method → 405 with Allow: GET', async () => {
    const response = await list(
      new Request(PAIRED_URL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${alice.bearer}`,
          [ATTESTATION_HEADER_NAME]: apiHeader(alice.device),
          ...uniqueClientIpHeader(),
        },
      }),
    );
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('GET');
  });
});
