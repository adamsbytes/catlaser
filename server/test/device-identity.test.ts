import { randomBytes } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { device, deviceAccessGrant, deviceAclRevision } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import { PROVISIONING_TOKEN_HEADER } from '~/lib/device-provisioning.ts';
import {
  buildDevicesAclRoute,
  buildDevicesPairingCodeRoute,
  DEVICES_PAIRING_CODE_PATH_PREFIX,
  DEVICES_PAIRING_CODE_PATH_SUFFIX,
  DEVICES_ACL_PATH_SUFFIX,
  DEVICES_PROVISION_PATH,
  devicesProvisionRoute,
} from '~/routes/devices.ts';
import {
  buildDeviceAttestationHeaders,
  createTestDeviceIdentity,
} from './support/signed-device-attestation.ts';
import type { TestDeviceIdentity } from './support/signed-device-attestation.ts';

/**
 * Coverage for the device-facing route surface (fix #2):
 *
 * 1. `POST /api/v1/devices/provision` — bootstrap registration
 *    authenticated by the pre-shared `PROVISIONING_TOKEN`.
 * 2. `POST /api/v1/devices/:slug/pairing-code` — device-attested
 *    fresh-code issuance.
 * 3. `GET /api/v1/devices/:slug/acl` — device-attested ACL poll.
 *
 * Every rejection path in `device-attestation.ts` is exercised with
 * a concrete trigger (missing header, skewed timestamp, signature
 * mismatch, unknown slug) so a regression in any individual check
 * surfaces in isolation. Happy-path calls document the full
 * round-trip: the device registers its Ed25519 public key, then
 * proves ownership on every subsequent call by signing a
 * `"dvc:" || METHOD || "\n" || path || "\n" || timestamp` byte
 * string under that key.
 */

const PROVISION_URL = `http://localhost${DEVICES_PROVISION_PATH}`;
const pairingCodeUrlFor = (slug: string): string =>
  `http://localhost${DEVICES_PAIRING_CODE_PATH_PREFIX}${slug}${DEVICES_PAIRING_CODE_PATH_SUFFIX}`;
const aclUrlFor = (slug: string): string =>
  `http://localhost${DEVICES_PAIRING_CODE_PATH_PREFIX}${slug}${DEVICES_ACL_PATH_SUFFIX}`;

const randomSlug = (): string => `dev-${randomBytes(4).toString('hex')}`;

/**
 * Random uppercase base32 pairing code. Matches the charset
 * `exchangePairingCode` accepts and avoids collisions across test
 * runs (the table's `code_hash` has a UNIQUE constraint).
 */
const randomPairingCode = (): string => {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const buf = randomBytes(32);
  let out = '';
  for (const byte of buf) {
    const char = alphabet[byte % 32];
    if (char === undefined) {
      throw new Error('unreachable');
    }
    out += char;
  }
  return out;
};

const successBodyShape = z.object({
  ok: z.literal(true),
  data: z.unknown(),
});

const errorBodyShape = z.object({
  ok: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
});

const pairingCodeShape = z.object({
  ok: z.literal(true),
  data: z.object({
    code: z.string().min(16).max(128),
    device_id: z.string().min(1),
    expires_at: z.string().min(1),
  }),
});

const aclShape = z.object({
  ok: z.literal(true),
  data: z.object({
    device_id: z.string().min(1),
    revision: z.number().int().nonnegative(),
    grants: z.array(
      z.object({
        user_spki_b64: z.string().min(1),
        revision: z.number().int().nonnegative(),
        granted_at: z.string().min(1),
      }),
    ),
  }),
});

const clearDeviceBySlug = async (slug: string): Promise<void> => {
  await db.delete(deviceAccessGrant).where(eq(deviceAccessGrant.deviceSlug, slug));
  await db.delete(deviceAclRevision).where(eq(deviceAclRevision.deviceSlug, slug));
  await db.delete(device).where(eq(device.slug, slug));
};

describe('POST /api/v1/devices/provision', () => {
  let fixture: TestDeviceIdentity;
  let slug: string;

  beforeEach(() => {
    fixture = createTestDeviceIdentity();
    slug = randomSlug();
  });

  afterEach(async () => {
    await clearDeviceBySlug(slug);
  });

  const validBody = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
    device_id: slug,
    public_key_ed25519: fixture.publicKeyBase64Url,
    tailscale_host: '100.64.0.42',
    tailscale_port: 9820,
    ...overrides,
  });

  const post = async (body: unknown, headers: Record<string, string> = {}): Promise<Response> =>
    await devicesProvisionRoute(
      new Request(PROVISION_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          [PROVISIONING_TOKEN_HEADER]: env.PROVISIONING_TOKEN,
          ...headers,
        },
        body: JSON.stringify(body),
      }),
    );

  test('registers a new device with 201', async () => {
    const response = await post(validBody());
    expect(response.status).toBe(201);
    const body = successBodyShape.parse(await response.json());
    expect(body.data).toEqual({ device_id: slug, created: true });
    const rows = await db.select().from(device).where(eq(device.slug, slug));
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('row should exist');
    }
    expect(row.publicKeyEd25519).toBe(fixture.publicKeyBase64Url);
  });

  test('re-provisioning the same slug updates the key and returns 200', async () => {
    await post(validBody());
    const rotated = createTestDeviceIdentity();
    const response = await post(validBody({ public_key_ed25519: rotated.publicKeyBase64Url }));
    expect(response.status).toBe(200);
    const body = successBodyShape.parse(await response.json());
    expect(body.data).toEqual({ device_id: slug, created: false });
    const [row] = await db.select().from(device).where(eq(device.slug, slug));
    if (row === undefined) {
      throw new Error('row should exist after re-provision');
    }
    expect(row.publicKeyEd25519).toBe(rotated.publicKeyBase64Url);
  });

  test('rejects missing provisioning token with 401', async () => {
    const response = await post(validBody(), { [PROVISIONING_TOKEN_HEADER]: '' });
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_TOKEN_REQUIRED');
  });

  test('rejects wrong provisioning token with 401', async () => {
    const response = await post(validBody(), {
      [PROVISIONING_TOKEN_HEADER]: 'wrong-token-that-is-long-enough-to-match-length-policy',
    });
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_TOKEN_INVALID');
  });

  test('rejects public key that is not 32 base64url bytes', async () => {
    const response = await post(validBody({ public_key_ed25519: 'AAAA' }));
    expect(response.status).toBe(400);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_BODY_INVALID');
  });

  test('rejects non-tailnet host', async () => {
    const response = await post(validBody({ tailscale_host: 'example.com' }));
    expect(response.status).toBe(400);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_BODY_INVALID');
  });

  test('rejects port out of range', async () => {
    const response = await post(validBody({ tailscale_port: 0 }));
    expect(response.status).toBe(400);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_BODY_INVALID');
  });

  test('rejects extra body fields (strictObject)', async () => {
    const response = await post(validBody({ unexpected: true }));
    expect(response.status).toBe(400);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('PROVISIONING_BODY_INVALID');
  });

  test('rejects wrong method with 405', async () => {
    const response = await devicesProvisionRoute(
      new Request(PROVISION_URL, {
        method: 'GET',
        headers: { [PROVISIONING_TOKEN_HEADER]: env.PROVISIONING_TOKEN },
      }),
    );
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
  });
});

describe('POST /api/v1/devices/:slug/pairing-code', () => {
  const fixedNow = 1_820_000_000;
  let fixture: TestDeviceIdentity;
  let slug: string;
  let pairingCode: (request: Request) => Promise<Response>;

  beforeEach(async () => {
    fixture = createTestDeviceIdentity();
    slug = randomSlug();
    pairingCode = buildDevicesPairingCodeRoute({ nowSeconds: () => fixedNow });
    // Provision the device so the device-attestation middleware can
    // find its public key.
    await devicesProvisionRoute(
      new Request(PROVISION_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          [PROVISIONING_TOKEN_HEADER]: env.PROVISIONING_TOKEN,
        },
        body: JSON.stringify({
          device_id: slug,
          public_key_ed25519: fixture.publicKeyBase64Url,
          tailscale_host: '100.64.0.42',
          tailscale_port: 9820,
        }),
      }),
    );
  });

  afterEach(async () => {
    await clearDeviceBySlug(slug);
  });

  const url = () => pairingCodeUrlFor(slug);
  const headers = (
    identity: TestDeviceIdentity = fixture,
    timestamp: number = fixedNow,
  ): Record<string, string> =>
    buildDeviceAttestationHeaders({
      identity,
      slug,
      method: 'POST',
      pathname: new URL(url()).pathname,
      timestamp,
    });

  test('issues a fresh pairing code to a registered device', async () => {
    const response = await pairingCode(new Request(url(), { method: 'POST', headers: headers() }));
    expect(response.status).toBe(200);
    const body = pairingCodeShape.parse(await response.json());
    expect(body.data.device_id).toBe(slug);
    expect(body.data.code).toMatch(/^[\dA-Z]{16,128}$/v);
  });

  test('rejects an unregistered device slug with 401', async () => {
    const ghostSlug = randomSlug();
    const ghostUrl = pairingCodeUrlFor(ghostSlug);
    const response = await pairingCode(
      new Request(ghostUrl, {
        method: 'POST',
        headers: buildDeviceAttestationHeaders({
          identity: fixture,
          slug: ghostSlug,
          method: 'POST',
          pathname: new URL(ghostUrl).pathname,
          timestamp: fixedNow,
        }),
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_DEVICE_NOT_REGISTERED');
  });

  test('rejects a signature produced by a different device key', async () => {
    const impostor = createTestDeviceIdentity();
    const response = await pairingCode(
      new Request(url(), { method: 'POST', headers: headers(impostor) }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_SIGNATURE_INVALID');
  });

  test('rejects skewed timestamp', async () => {
    const response = await pairingCode(
      new Request(url(), {
        method: 'POST',
        headers: headers(fixture, fixedNow - 120),
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_SKEW_EXCEEDED');
  });

  test('rejects missing attestation headers', async () => {
    const response = await pairingCode(new Request(url(), { method: 'POST' }));
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_REQUIRED');
  });

  test('rejects mismatched pathname in the signed payload', async () => {
    // Sign for a different path, submit against `url()`. The
    // signature should fail to verify because the reconstructed
    // signed bytes embed the URL pathname.
    const wrongHeaders = buildDeviceAttestationHeaders({
      identity: fixture,
      slug,
      method: 'POST',
      pathname: '/api/v1/devices/wrong/pairing-code',
      timestamp: fixedNow,
    });
    const response = await pairingCode(
      new Request(url(), { method: 'POST', headers: wrongHeaders }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_SIGNATURE_INVALID');
  });

  test('rejects wrong method with 405', async () => {
    const response = await pairingCode(new Request(url(), { method: 'GET', headers: headers() }));
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
  });
});

describe('pair-claim ACL integration', () => {
  // These are end-to-end tests covering the invariant:
  //
  //   `exchangePairingCode` → atomically writes a
  //   `device_access_grant` row → `GET /api/v1/devices/:slug/acl`
  //   returns that row.
  //
  // Cross-cuts the user-side and device-side trust channels because
  // that's the transition the whole fix #2 design hinges on. Tests
  // stay lightweight by calling `exchangePairingCode` directly rather
  // than composing a full magic-link sign-in; the attestation and
  // idempotency gates are covered by `device-pairing.test.ts`.

  const fixedNow = 1_820_000_000;
  let fixture: TestDeviceIdentity;
  let slug: string;
  let acl: (request: Request) => Promise<Response>;

  beforeEach(async () => {
    fixture = createTestDeviceIdentity();
    slug = randomSlug();
    acl = buildDevicesAclRoute({ nowSeconds: () => fixedNow });
    await devicesProvisionRoute(
      new Request(PROVISION_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          [PROVISIONING_TOKEN_HEADER]: env.PROVISIONING_TOKEN,
        },
        body: JSON.stringify({
          device_id: slug,
          public_key_ed25519: fixture.publicKeyBase64Url,
          tailscale_host: '100.64.0.42',
          tailscale_port: 9820,
        }),
      }),
    );
  });

  afterEach(async () => {
    await clearDeviceBySlug(slug);
  });

  test('ACL reflects the user_spki of the most recent pair claim', async () => {
    // Use Drizzle directly to seed the session + session_attestation
    // the pair claim will read from. This avoids running a full
    // sign-in ceremony inside a test that's focused on the
    // ACL-on-claim invariant.
    const userId = `user-${randomBytes(4).toString('hex')}`;
    const sessionId = `sess-${randomBytes(4).toString('hex')}`;
    const email = `${userId}@example.com`;
    const spki = Buffer.from(randomBytes(91)).toString('base64');

    const { session, sessionAttestation, user } = await import('~/db/schema.ts');
    await db.insert(user).values({
      id: userId,
      name: 'Alice',
      email,
      emailVerified: true,
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    try {
      await db.insert(session).values({
        id: sessionId,
        userId,
        token: `tok-${randomBytes(8).toString('hex')}`,
        createdAt: new Date(),
        updatedAt: new Date(),
        expiresAt: new Date(Date.now() + 3600 * 1000),
      });
      await db.insert(sessionAttestation).values({
        id: `sa-${randomBytes(4).toString('hex')}`,
        sessionId,
        fingerprintHash: Buffer.from(randomBytes(32))
          .toString('base64')
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', ''),
        publicKeySpki: spki,
        createdAt: new Date(),
      });

      const { exchangePairingCode, issuePairingCode } = await import('~/lib/device-pairing.ts');
      const code = randomPairingCode();
      await issuePairingCode({
        code,
        deviceId: slug,
        tailscaleHost: '100.64.0.42',
        tailscalePort: 9820,
      });
      const outcome = await exchangePairingCode({
        code,
        deviceId: slug,
        userId,
        sessionId,
      });
      expect(outcome.kind).toBe('ok');

      // The ACL endpoint must now surface this SPKI.
      const response = await acl(
        new Request(aclUrlFor(slug), {
          method: 'GET',
          headers: buildDeviceAttestationHeaders({
            identity: fixture,
            slug,
            method: 'GET',
            pathname: new URL(aclUrlFor(slug)).pathname,
            timestamp: fixedNow,
          }),
        }),
      );
      expect(response.status).toBe(200);
      const body = aclShape.parse(await response.json());
      expect(body.data.device_id).toBe(slug);
      expect(body.data.grants).toHaveLength(1);
      const [grant] = body.data.grants;
      if (grant === undefined) {
        throw new Error('expected one grant');
      }
      expect(grant.user_spki_b64).toBe(spki);
      expect(body.data.revision).toBe(1);
    } finally {
      await db.delete(session).where(eq(session.id, sessionId));
      await db.delete(user).where(eq(user.id, userId));
    }
  });

  test('re-pair by a different user revokes the prior grant', async () => {
    const { session, sessionAttestation, user } = await import('~/db/schema.ts');
    const { exchangePairingCode, issuePairingCode } = await import('~/lib/device-pairing.ts');

    const aliceId = `user-${randomBytes(4).toString('hex')}`;
    const aliceSession = `sess-${randomBytes(4).toString('hex')}`;
    const aliceSpki = Buffer.from(randomBytes(91)).toString('base64');
    const bobId = `user-${randomBytes(4).toString('hex')}`;
    const bobSession = `sess-${randomBytes(4).toString('hex')}`;
    const bobSpki = Buffer.from(randomBytes(91)).toString('base64');

    await db.insert(user).values([
      {
        id: aliceId,
        name: 'Alice',
        email: `${aliceId}@example.com`,
        emailVerified: true,
        createdAt: new Date(),
        updatedAt: new Date(),
      },
      {
        id: bobId,
        name: 'Bob',
        email: `${bobId}@example.com`,
        emailVerified: true,
        createdAt: new Date(),
        updatedAt: new Date(),
      },
    ]);
    try {
      const seeds = [
        [aliceSession, aliceId, aliceSpki],
        [bobSession, bobId, bobSpki],
      ] as const;
      await Promise.all(
        seeds.map(async ([id, userId, spki]) => {
          await db.insert(session).values({
            id,
            userId,
            token: `tok-${randomBytes(8).toString('hex')}`,
            createdAt: new Date(),
            updatedAt: new Date(),
            expiresAt: new Date(Date.now() + 3600 * 1000),
          });
          await db.insert(sessionAttestation).values({
            id: `sa-${randomBytes(4).toString('hex')}`,
            sessionId: id,
            fingerprintHash: Buffer.from(randomBytes(32))
              .toString('base64')
              .replaceAll('+', '-')
              .replaceAll('/', '_')
              .replaceAll('=', ''),
            publicKeySpki: spki,
            createdAt: new Date(),
          });
        }),
      );

      const aliceCode = randomPairingCode();
      const bobCode = randomPairingCode();
      await issuePairingCode({
        code: aliceCode,
        deviceId: slug,
        tailscaleHost: '100.64.0.42',
        tailscalePort: 9820,
      });
      const aliceOutcome = await exchangePairingCode({
        code: aliceCode,
        deviceId: slug,
        userId: aliceId,
        sessionId: aliceSession,
      });
      expect(aliceOutcome.kind).toBe('ok');

      await issuePairingCode({
        code: bobCode,
        deviceId: slug,
        tailscaleHost: '100.64.0.43',
        tailscalePort: 9820,
      });
      const bobOutcome = await exchangePairingCode({
        code: bobCode,
        deviceId: slug,
        userId: bobId,
        sessionId: bobSession,
      });
      expect(bobOutcome.kind).toBe('ok');

      // ACL must show Bob's SPKI as the single active grant; Alice's
      // grant must still be in the row but revoked.
      const response = await acl(
        new Request(aclUrlFor(slug), {
          method: 'GET',
          headers: buildDeviceAttestationHeaders({
            identity: fixture,
            slug,
            method: 'GET',
            pathname: new URL(aclUrlFor(slug)).pathname,
            timestamp: fixedNow,
          }),
        }),
      );
      expect(response.status).toBe(200);
      const body = aclShape.parse(await response.json());
      expect(body.data.grants).toHaveLength(1);
      const [grant] = body.data.grants;
      if (grant === undefined) {
        throw new Error('expected one active grant');
      }
      expect(grant.user_spki_b64).toBe(bobSpki);
      expect(body.data.revision).toBe(2);

      // The DB row for Alice must be present-but-revoked.
      const aliceGrants = await db
        .select()
        .from(deviceAccessGrant)
        .where(eq(deviceAccessGrant.userSpkiB64, aliceSpki));
      expect(aliceGrants).toHaveLength(1);
      const [aliceGrant] = aliceGrants;
      if (aliceGrant === undefined) {
        throw new Error('expected alice grant row');
      }
      expect(aliceGrant.revokedAt).not.toBeNull();
    } finally {
      await db.delete(session).where(eq(session.id, aliceSession));
      await db.delete(session).where(eq(session.id, bobSession));
      await db.delete(user).where(eq(user.id, aliceId));
      await db.delete(user).where(eq(user.id, bobId));
    }
  });
});

describe('GET /api/v1/devices/:slug/acl', () => {
  const fixedNow = 1_820_000_000;
  let fixture: TestDeviceIdentity;
  let slug: string;
  let acl: (request: Request) => Promise<Response>;

  beforeEach(async () => {
    fixture = createTestDeviceIdentity();
    slug = randomSlug();
    acl = buildDevicesAclRoute({ nowSeconds: () => fixedNow });
    await devicesProvisionRoute(
      new Request(PROVISION_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          [PROVISIONING_TOKEN_HEADER]: env.PROVISIONING_TOKEN,
        },
        body: JSON.stringify({
          device_id: slug,
          public_key_ed25519: fixture.publicKeyBase64Url,
          tailscale_host: '100.64.0.42',
          tailscale_port: 9820,
        }),
      }),
    );
  });

  afterEach(async () => {
    await clearDeviceBySlug(slug);
  });

  const url = () => aclUrlFor(slug);
  const headers = (): Record<string, string> =>
    buildDeviceAttestationHeaders({
      identity: fixture,
      slug,
      method: 'GET',
      pathname: new URL(url()).pathname,
      timestamp: fixedNow,
    });

  test('returns an empty ACL for a freshly-provisioned device', async () => {
    const response = await acl(new Request(url(), { method: 'GET', headers: headers() }));
    expect(response.status).toBe(200);
    const body = aclShape.parse(await response.json());
    expect(body.data.device_id).toBe(slug);
    expect(body.data.revision).toBe(0);
    expect(body.data.grants).toHaveLength(0);
  });

  test('rejects an unregistered device with 401', async () => {
    const ghostSlug = randomSlug();
    const ghostUrl = aclUrlFor(ghostSlug);
    const response = await acl(
      new Request(ghostUrl, {
        method: 'GET',
        headers: buildDeviceAttestationHeaders({
          identity: fixture,
          slug: ghostSlug,
          method: 'GET',
          pathname: new URL(ghostUrl).pathname,
          timestamp: fixedNow,
        }),
      }),
    );
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_DEVICE_NOT_REGISTERED');
  });

  test('rejects wrong method with 405', async () => {
    const response = await acl(new Request(url(), { method: 'POST', headers: headers() }));
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('GET');
  });

  test('rejects missing headers', async () => {
    const response = await acl(new Request(url(), { method: 'GET' }));
    expect(response.status).toBe(401);
    const body = errorBodyShape.parse(await response.json());
    expect(body.error.code).toBe('DEVICE_ATTESTATION_REQUIRED');
  });
});
