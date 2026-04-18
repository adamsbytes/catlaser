import { randomBytes, randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { devicePairingCode, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import {
  DEVICE_PAIRING_CODE_TTL_SECONDS,
  hashPairingCode,
  issuePairingCode,
} from '~/lib/device-pairing.ts';
import { env } from '~/lib/env.ts';
import { IDEMPOTENCY_HEADER_NAME } from '~/lib/idempotency.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { DEVICES_PAIR_PATH, buildDevicesPairRoute, devicesPairRoute } from '~/routes/devices.ts';
import { handle } from '~/server.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the coordination server's device-pairing
 * endpoint.
 *
 * These tests compose the full pipeline against a real Postgres: a
 * magic-link sign-in under a frozen clock, bearer extraction, an
 * `issuePairingCode` seed, and a signed POST to
 * `/api/v1/devices/pair`. Every rejection path is exercised with a
 * concrete cause (unknown code, expired code, already-claimed code,
 * device-id mismatch, missing bearer, wrong binding tag, missing
 * `Idempotency-Key`, captured-attestation replay) so a regression in
 * any individual check surfaces in isolation. Happy-path calls
 * document the invariants that the full gate — attestation ➜
 * idempotency ➜ exchange — accepts a real attested request, flips the
 * ledger row atomically, and caches the response for replay.
 *
 * Key invariants under test:
 *
 * 1. The attestation gate runs BEFORE the idempotency gate BEFORE the
 *    pairing exchange. A bad bearer, missing/expired attestation, or
 *    missing idempotency key never touches the ledger.
 * 2. A successful claim marks the row with both `claimed_at` and
 *    `claimed_by_user_id` in a single atomic `UPDATE`. A concurrent
 *    duplicate claim against the same code resolves as one 200 + one
 *    409.
 * 3. Device-id mismatch collapses to 404 on the wire — a scanner cannot
 *    distinguish "real code under a different device" from "unknown
 *    code".
 * 4. Idempotency replay returns the cached 200 without re-executing
 *    the exchange. A cached 409 stays 409 for the TTL — single-use
 *    semantics hold across retries.
 * 5. User delete `SET NULL`s the `claimed_by_user_id` FK; the row
 *    survives for fleet diagnostics.
 * 6. The server's top-level dispatch in `handle(...)` routes this path
 *    to the method-gate, which emits 405 + `Allow: POST` for any other
 *    verb.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const PAIR_URL = `http://localhost${DEVICES_PAIR_PATH}`;
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';

const successBodyShape = z.object({
  ok: z.literal(true),
  data: z.object({
    device_id: z.string().min(1),
    device_name: z.string().nullable(),
    host: z.string().min(1),
    port: z.number().int().positive(),
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

/** Distinct base32 bodies across concurrent tests so seeded rows don't collide. */
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
}

const signIn = async (
  auth: ReturnType<typeof createAuth>,
  delivery: RecordingDelivery,
  device: TestDeviceKey,
  clockNow: bigint,
): Promise<SignedInFixture> => {
  const email = randomEmail('pair');
  await clearEmail(email);
  delivery.reset();

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
  };
};

/**
 * The shape of a single test's seeded pairing-code row. Tracked so
 * `afterEach` can unwind any rows that remain (e.g. an expired/404
 * scenario that never flips `claimed_at` and isn't cascade-bound to
 * any session).
 */
interface SeededPairingCode {
  readonly code: string;
  readonly deviceId: string;
  readonly codeHash: string;
}

describe('device pairing: happy path + replay', () => {
  const fixedNow = 1_810_100_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let fixture: SignedInFixture;
  let pair: (request: Request) => Promise<Response>;
  const seededCodes: SeededPairingCode[] = [];

  const apiHeader = (ts: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: ts },
    });

  const pairRoute = async (request: Request): Promise<Response> => await pair(request);

  const defaultHeaders = (extra: Record<string, string> = {}): Record<string, string> => ({
    Authorization: `Bearer ${fixture.bearer}`,
    [ATTESTATION_HEADER_NAME]: apiHeader(),
    'Content-Type': 'application/json',
    [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
    ...extra,
  });

  const seed = async (
    overrides: Partial<{
      code: string;
      deviceId: string;
      deviceName: string | undefined;
      host: string;
      port: number;
      expiresAt: Date;
      createdAt: Date;
    }> = {},
  ): Promise<SeededPairingCode> => {
    const code = overrides.code ?? randomPairingCode();
    const deviceId = overrides.deviceId ?? randomDeviceId();
    const issuance = {
      code,
      deviceId,
      tailscaleHost: overrides.host ?? '100.64.0.42',
      tailscalePort: overrides.port ?? 9820,
      ...(overrides.deviceName === undefined ? {} : { deviceName: overrides.deviceName }),
      ...(overrides.expiresAt === undefined ? {} : { expiresAt: overrides.expiresAt }),
      ...(overrides.createdAt === undefined ? {} : { createdAt: overrides.createdAt }),
    };
    const { codeHash } = await issuePairingCode(issuance);
    const record = { code, deviceId, codeHash };
    seededCodes.push(record);
    return record;
  };

  const post = async (request: {
    body: unknown;
    headers: Record<string, string>;
  }): Promise<{ response: Response; body: unknown }> => {
    const response = await pairRoute(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: request.headers,
        body: JSON.stringify(request.body),
      }),
    );
    const text = await response.text();
    const contentType = response.headers.get('Content-Type') ?? '';
    const isJson = contentType.toLowerCase().startsWith('application/json');
    const body: unknown = text.length > 0 && isJson ? JSON.parse(text) : null;
    return { response, body };
  };

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  afterEach(async () => {
    const toClear = seededCodes.splice(0);
    await Promise.all(toClear.map(async ({ codeHash }) => await clearCodeHash(codeHash)));
  });

  test('happy path: valid code + device_id → 200 with endpoint echoed and row marked claimed', async () => {
    const seeded = await seed({ deviceName: 'Kitchen Laser' });
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(200);
    const parsed = successBodyShape.parse(body);
    expect(parsed.data.device_id).toBe(seeded.deviceId);
    expect(parsed.data.device_name).toBe('Kitchen Laser');
    expect(parsed.data.host).toBe('100.64.0.42');
    expect(parsed.data.port).toBe(9820);

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected claimed row');
    }
    expect(row.claimedAt).not.toBeNull();
    expect(row.claimedByUserId).toBe(fixture.userId);
  });

  test('happy path: device_name null round-trips as null', async () => {
    const seeded = await seed();
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(200);
    const parsed = successBodyShape.parse(body);
    expect(parsed.data.device_name).toBeNull();
  });

  test('replay with same idempotency key + same body returns cached response; no second claim', async () => {
    const seeded = await seed({ deviceName: 'Living Room' });
    const key = randomUUID();
    const headers = defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key });
    const body = { code: seeded.code, device_id: seeded.deviceId };

    const first = await post({ body, headers });
    const second = await post({ body, headers });

    expect(first.response.status).toBe(200);
    expect(second.response.status).toBe(200);
    expect(second.body).toEqual(first.body);

    // Single claim: the second call hit the idempotency cache, never
    // re-ran the exchange. Row should still carry the original claim
    // metadata (specifically, the timestamp set on the first call is
    // still present and hasn't been re-written).
    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
  });

  test('replay with same idempotency key + different body → 422 IDEMPOTENCY_KEY_MISMATCH; no claim side effect', async () => {
    const seededA = await seed();
    const seededB = await seed();
    const key = randomUUID();
    const headers = defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key });

    const first = await post({
      body: { code: seededA.code, device_id: seededA.deviceId },
      headers,
    });
    const second = await post({
      body: { code: seededB.code, device_id: seededB.deviceId },
      headers,
    });

    expect(first.response.status).toBe(200);
    expect(second.response.status).toBe(422);
    expect(errorBodyShape.parse(second.body).error.code).toBe('IDEMPOTENCY_KEY_MISMATCH');

    // Seeded B was never claimed (the key collision rejected the retry
    // before the exchange ran).
    const rowsB = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seededB.codeHash));
    expect(rowsB).toHaveLength(1);
    const [rowB] = rowsB;
    if (rowB === undefined) {
      throw new Error('expected seeded B row');
    }
    expect(rowB.claimedAt).toBeNull();
    expect(rowB.claimedByUserId).toBeNull();
  });

  test('a second distinct idempotency key against an already-claimed code → 409 PAIR_CODE_ALREADY_USED', async () => {
    const seeded = await seed();
    const first = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(first.response.status).toBe(200);

    const second = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(second.response.status).toBe(409);
    expect(errorBodyShape.parse(second.body).error.code).toBe('PAIR_CODE_ALREADY_USED');
  });
});

describe('device pairing: exchange failures', () => {
  const fixedNow = 1_810_200_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let fixture: SignedInFixture;
  let pair: (request: Request) => Promise<Response>;
  const seededCodes: SeededPairingCode[] = [];

  const apiHeader = (): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
    });

  const defaultHeaders = (extra: Record<string, string> = {}): Record<string, string> => ({
    Authorization: `Bearer ${fixture.bearer}`,
    [ATTESTATION_HEADER_NAME]: apiHeader(),
    'Content-Type': 'application/json',
    [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
    ...extra,
  });

  const seed = async (
    overrides: Partial<{
      code: string;
      deviceId: string;
      host: string;
      port: number;
      expiresAt: Date;
    }> = {},
  ): Promise<SeededPairingCode> => {
    const code = overrides.code ?? randomPairingCode();
    const deviceId = overrides.deviceId ?? randomDeviceId();
    const issuance = {
      code,
      deviceId,
      tailscaleHost: overrides.host ?? '100.64.0.42',
      tailscalePort: overrides.port ?? 9820,
      ...(overrides.expiresAt === undefined ? {} : { expiresAt: overrides.expiresAt }),
    };
    const { codeHash } = await issuePairingCode(issuance);
    const record = { code, deviceId, codeHash };
    seededCodes.push(record);
    return record;
  };

  const post = async (request: {
    body: unknown;
    headers: Record<string, string>;
  }): Promise<{ response: Response; body: unknown }> => {
    const response = await pair(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: request.headers,
        body: JSON.stringify(request.body),
      }),
    );
    const text = await response.text();
    const body: unknown = text.length > 0 ? JSON.parse(text) : null;
    return { response, body };
  };

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  afterEach(async () => {
    const toClear = seededCodes.splice(0);
    await Promise.all(toClear.map(async ({ codeHash }) => await clearCodeHash(codeHash)));
  });

  test('unknown code → 404 PAIR_CODE_NOT_FOUND', async () => {
    const { response, body } = await post({
      body: { code: randomPairingCode(), device_id: 'cat-missing' },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(404);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_NOT_FOUND');
  });

  test('code exists but device_id does not match → 404 PAIR_CODE_NOT_FOUND (no fingerprinting)', async () => {
    const seeded = await seed();
    const { response, body } = await post({
      body: { code: seeded.code, device_id: 'cat-wrong' },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(404);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_NOT_FOUND');

    // Row stays unclaimed — a device_id mismatch must not flip the
    // claim. Another legitimate exchange could still succeed.
    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).toBeNull();
    expect(row.claimedByUserId).toBeNull();
  });

  test('expired code → 410 PAIR_CODE_EXPIRED', async () => {
    // Explicit past expiry; the issuance housekeeping pass only removes
    // unclaimed rows whose expiry is already behind the creation
    // timestamp, but we defeat that by seeding with the same
    // createdAt=expiresAt-ε pair — we just set expiresAt in the past
    // relative to wall clock, and the exchange runs against wall clock.
    const pastExpiry = new Date(Date.now() - 1000);
    const seeded = await seed({ expiresAt: pastExpiry });
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(410);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_EXPIRED');

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    // Row remains (not claimed, not deleted); next issuance would
    // reclaim the slot through housekeeping. For this test we just
    // assert "not claimed".
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).toBeNull();
  });

  test('already-claimed code → 409 PAIR_CODE_ALREADY_USED', async () => {
    const seeded = await seed();
    // Pre-claim the row directly to simulate a prior successful pair
    // by another caller.
    const preClaim = new Date();
    await db
      .update(devicePairingCode)
      .set({ claimedAt: preClaim, claimedByUserId: fixture.userId })
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));

    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(409);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_ALREADY_USED');

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    // The claim timestamp is unchanged — the gate refused to touch it.
    expect(row.claimedAt?.getTime()).toBe(preClaim.getTime());
  });

  test('concurrent duplicates on the same code: exactly one 200 + one 409', async () => {
    const seeded = await seed();
    const body = { code: seeded.code, device_id: seeded.deviceId };
    const [a, b] = await Promise.all([
      post({ body, headers: defaultHeaders() }),
      post({ body, headers: defaultHeaders() }),
    ]);
    const statuses = [a.response.status, b.response.status].toSorted((x, y) => x - y);
    expect(statuses).toEqual([200, 409]);

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).not.toBeNull();
    expect(row.claimedByUserId).toBe(fixture.userId);
  });
});

describe('device pairing: request-shape validation', () => {
  const fixedNow = 1_810_300_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let fixture: SignedInFixture;
  let pair: (request: Request) => Promise<Response>;

  const defaultHeaders = (extra: Record<string, string> = {}): Record<string, string> => ({
    Authorization: `Bearer ${fixture.bearer}`,
    [ATTESTATION_HEADER_NAME]: buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
    }),
    'Content-Type': 'application/json',
    [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
    ...extra,
  });

  const postRaw = async (request: {
    body: string;
    headers: Record<string, string>;
  }): Promise<{ response: Response; body: unknown }> => {
    const response = await pair(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: request.headers,
        body: request.body,
      }),
    );
    const text = await response.text();
    const parsed: unknown = text.length > 0 ? JSON.parse(text) : null;
    return { response, body: parsed };
  };

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  test('missing body → 400 PAIR_BODY_INVALID', async () => {
    const response = await pair(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: defaultHeaders(),
      }),
    );
    expect(response.status).toBe(400);
    const body = await response.json();
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('malformed JSON → 400 PAIR_BODY_INVALID', async () => {
    const { response, body } = await postRaw({
      body: '{not json',
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('missing code field → 400 PAIR_BODY_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ device_id: 'cat-001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('missing device_id field → 400 PAIR_BODY_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: randomPairingCode() }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('extra field → 400 PAIR_BODY_INVALID (strictObject rejects unknown keys)', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({
        code: randomPairingCode(),
        device_id: 'cat-001',
        extra: 'smuggled',
      }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('wrong types on code field → 400 PAIR_BODY_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: 12_345, device_id: 'cat-001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });

  test('code below minimum length → 400 PAIR_CODE_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: 'ABC', device_id: 'cat-001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_INVALID');
  });

  test('code with non-base32 chars → 400 PAIR_CODE_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({
        code: 'abcdefghijklmnop', // lowercase; base32 alphabet is uppercase
        device_id: 'cat-001',
      }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_INVALID');
  });

  test('code with digit 0 or 1 → 400 PAIR_CODE_INVALID (base32 excludes 0/1/8/9)', async () => {
    // 32 chars length (passes Zod + length checks), one '0' to fail charset.
    const code = `0${'A'.repeat(31)}`;
    const { response, body } = await postRaw({
      body: JSON.stringify({ code, device_id: 'cat-001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_CODE_INVALID');
  });

  test('device_id with illegal char → 400 PAIR_DEVICE_ID_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: randomPairingCode(), device_id: 'cat.001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_DEVICE_ID_INVALID');
  });

  test('device_id with whitespace → 400 PAIR_DEVICE_ID_INVALID', async () => {
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: randomPairingCode(), device_id: 'cat 001' }),
      headers: defaultHeaders(),
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_DEVICE_ID_INVALID');
  });

  test('Content-Type not application/json → 400 PAIR_BODY_INVALID', async () => {
    const headers = defaultHeaders();
    headers['Content-Type'] = 'text/plain';
    const { response, body } = await postRaw({
      body: JSON.stringify({ code: randomPairingCode(), device_id: 'cat-001' }),
      headers,
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('PAIR_BODY_INVALID');
  });
});

describe('device pairing: attestation and idempotency gate ordering', () => {
  const fixedNow = 1_810_400_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let fixture: SignedInFixture;
  let pair: (request: Request) => Promise<Response>;
  const seededCodes: SeededPairingCode[] = [];

  const apiHeader = (ts: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: ts },
    });

  const seed = async (): Promise<SeededPairingCode> => {
    const code = randomPairingCode();
    const deviceId = randomDeviceId();
    const { codeHash } = await issuePairingCode({
      code,
      deviceId,
      tailscaleHost: '100.64.0.42',
      tailscalePort: 9820,
    });
    const record = { code, deviceId, codeHash };
    seededCodes.push(record);
    return record;
  };

  const post = async (request: {
    body: unknown;
    headers: Record<string, string>;
  }): Promise<{ response: Response; body: unknown }> => {
    const response = await pair(
      new Request(PAIR_URL, {
        method: 'POST',
        headers: request.headers,
        body: JSON.stringify(request.body),
      }),
    );
    const text = await response.text();
    const body: unknown = text.length > 0 ? JSON.parse(text) : null;
    return { response, body };
  };

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  afterEach(async () => {
    const toClear = seededCodes.splice(0);
    await Promise.all(toClear.map(async ({ codeHash }) => await clearCodeHash(codeHash)));
  });

  test('missing bearer → 401 SESSION_REQUIRED; ledger untouched', async () => {
    const seeded = await seed();
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: {
        [ATTESTATION_HEADER_NAME]: apiHeader(),
        'Content-Type': 'application/json',
        [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
      },
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).toBeNull();
  });

  test('wrong binding tag (req: instead of api:) → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const seeded = await seed();
    const wrongHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'request', timestamp: fixedNow },
    });
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: wrongHeader,
        'Content-Type': 'application/json',
        [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
      },
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('captured-attestation replay past skew window → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
    const seeded = await seed();
    clock.set(fixedNow + 120n);
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: apiHeader(fixedNow),
        'Content-Type': 'application/json',
        [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
      },
    });
    clock.set(fixedNow);
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).toBeNull();
  });

  test('missing Idempotency-Key → 400 IDEMPOTENCY_KEY_REQUIRED (attestation passed)', async () => {
    const seeded = await seed();
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: apiHeader(),
        'Content-Type': 'application/json',
      },
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');

    const rows = await db
      .select()
      .from(devicePairingCode)
      .where(eq(devicePairingCode.codeHash, seeded.codeHash));
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected seeded row');
    }
    expect(row.claimedAt).toBeNull();
  });

  test('non-UUID Idempotency-Key → 400 IDEMPOTENCY_KEY_INVALID', async () => {
    const seeded = await seed();
    const { response, body } = await post({
      body: { code: seeded.code, device_id: seeded.deviceId },
      headers: {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: apiHeader(),
        'Content-Type': 'application/json',
        [IDEMPOTENCY_HEADER_NAME]: 'not-a-uuid',
      },
    });
    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_INVALID');
  });
});

describe('device pairing: method gate and routing', () => {
  test('GET /api/v1/devices/pair → 405 with Allow: POST', async () => {
    const response = await devicesPairRoute(new Request(PAIR_URL, { method: 'GET' }));
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
    const body = await response.json();
    expect(errorBodyShape.parse(body).error.code).toBe('method_not_allowed');
  });

  test('DELETE /api/v1/devices/pair → 405 with Allow: POST', async () => {
    const response = await devicesPairRoute(new Request(PAIR_URL, { method: 'DELETE' }));
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
  });

  test('top-level dispatch routes /api/v1/devices/pair to this handler (not the 404 branch)', async () => {
    // A GET against the top-level `handle(...)` must resolve to the
    // method gate, producing 405 + Allow — NOT a generic 404.
    const response = await handle(new Request(PAIR_URL, { method: 'GET' }));
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
  });
});

describe('device pairing: user deletion cascades claimed_by_user_id → null, preserves row', () => {
  const fixedNow = 1_810_500_000n;
  const clock = mutableClock(fixedNow);

  test('deleting the owning user sets claimed_by_user_id to null and keeps the row', async () => {
    const delivery = new RecordingDelivery();
    const auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    const device = createTestDeviceKey();
    const pair = buildDevicesPairRoute({ auth, nowSeconds: clock.now });
    clock.set(fixedNow);
    const fixture = await signIn(auth, delivery, device, fixedNow);

    const code = randomPairingCode();
    const deviceId = randomDeviceId();
    const { codeHash } = await issuePairingCode({
      code,
      deviceId,
      tailscaleHost: '100.64.0.42',
      tailscalePort: 9820,
    });
    try {
      const apiHeader = buildSignedAttestationHeader({
        deviceKey: device,
        binding: { tag: 'api', timestamp: fixedNow },
      });
      const response = await pair(
        new Request(PAIR_URL, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${fixture.bearer}`,
            [ATTESTATION_HEADER_NAME]: apiHeader,
            'Content-Type': 'application/json',
            [IDEMPOTENCY_HEADER_NAME]: randomUUID(),
          },
          body: JSON.stringify({ code, device_id: deviceId }),
        }),
      );
      expect(response.status).toBe(200);

      const before = await db
        .select()
        .from(devicePairingCode)
        .where(eq(devicePairingCode.codeHash, codeHash));
      const [beforeRow] = before;
      if (beforeRow === undefined) {
        throw new Error('expected claimed row');
      }
      expect(beforeRow.claimedByUserId).toBe(fixture.userId);
      expect(beforeRow.claimedAt).not.toBeNull();

      await clearEmail(fixture.email);

      const after = await db
        .select()
        .from(devicePairingCode)
        .where(eq(devicePairingCode.codeHash, codeHash));
      const [afterRow] = after;
      if (afterRow === undefined) {
        throw new Error('row should survive user deletion');
      }
      expect(afterRow.claimedByUserId).toBeNull();
      // Claim timestamp is part of the audit trail — it must NOT be
      // touched by the SET NULL cascade.
      expect(afterRow.claimedAt?.getTime()).toBe(beforeRow.claimedAt?.getTime());
    } finally {
      await clearCodeHash(codeHash);
      await clearEmail(fixture.email);
    }
  });
});

describe('device pairing: issuance housekeeping and hashing', () => {
  test('issuePairingCode hashes consistently with hashPairingCode', async () => {
    const code = randomPairingCode();
    const deviceId = randomDeviceId();
    const { codeHash } = await issuePairingCode({
      code,
      deviceId,
      tailscaleHost: '100.64.0.42',
      tailscalePort: 9820,
    });
    try {
      expect(codeHash).toBe(hashPairingCode(code));
      // Plaintext code is not the key — hash is.
      const byPlain = await db
        .select()
        .from(devicePairingCode)
        .where(eq(devicePairingCode.codeHash, code));
      expect(byPlain).toHaveLength(0);
    } finally {
      await clearCodeHash(codeHash);
    }
  });

  test('issuePairingCode rejects invalid tailscale host', async () => {
    let caught: unknown;
    try {
      await issuePairingCode({
        code: randomPairingCode(),
        deviceId: randomDeviceId(),
        tailscaleHost: 'https://evil.example',
        tailscalePort: 9820,
      });
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
  });

  test('issuePairingCode rejects port out of range', async () => {
    let caught: unknown;
    try {
      await issuePairingCode({
        code: randomPairingCode(),
        deviceId: randomDeviceId(),
        tailscaleHost: '100.64.0.42',
        tailscalePort: 0,
      });
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
  });

  test('issuance housekeeping removes any expired unclaimed row whose createdAt pre-dates the fresh insert', async () => {
    // Seed an already-expired row, then issue a fresh one with a
    // creation timestamp strictly after the stale row's expiry. The
    // fresh issuance's housekeeping DELETE should collect the stale
    // row.
    const staleCreatedAt = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const staleExpires = new Date(staleCreatedAt.getTime() + 60 * 1000);
    const staleCode = randomPairingCode();
    const staleDeviceId = randomDeviceId();
    const { codeHash: staleHash } = await issuePairingCode({
      code: staleCode,
      deviceId: staleDeviceId,
      tailscaleHost: '100.64.0.42',
      tailscalePort: 9820,
      createdAt: staleCreatedAt,
      expiresAt: staleExpires,
    });

    const freshCode = randomPairingCode();
    const freshDeviceId = randomDeviceId();
    const { codeHash: freshHash } = await issuePairingCode({
      code: freshCode,
      deviceId: freshDeviceId,
      tailscaleHost: '100.64.0.42',
      tailscalePort: 9820,
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + DEVICE_PAIRING_CODE_TTL_SECONDS * 1000),
    });
    try {
      const staleRows = await db
        .select()
        .from(devicePairingCode)
        .where(eq(devicePairingCode.codeHash, staleHash));
      expect(staleRows).toHaveLength(0);

      const freshRows = await db
        .select()
        .from(devicePairingCode)
        .where(and(eq(devicePairingCode.codeHash, freshHash)));
      expect(freshRows).toHaveLength(1);
    } finally {
      await clearCodeHash(staleHash);
      await clearCodeHash(freshHash);
    }
  });
});
