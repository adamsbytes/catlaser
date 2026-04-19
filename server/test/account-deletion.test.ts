import { randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { deviceAccessGrant, deviceAclRevision, session, user } from '~/db/schema.ts';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { ATTESTATION_SKEW_SECONDS } from '~/lib/attestation-skew.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { ACCOUNT_DELETE_PATH, buildAccountDeleteRoute } from '~/routes/account.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * Coverage for `POST /api/v1/me/delete` — the account-deletion
 * route.
 *
 * The gate under test is ``withDeleteAccountAttestedSession``,
 * which accepts ONLY a `del:` binding. Every other attestation tag
 * — including the universal `api:` tag used by protected routes
 * like /me — must be refused here; that refusal is the single
 * structural separator between "I authenticated an API call" and
 * "I authenticated the permanent destruction of this account."
 *
 * Happy-path tests also assert the database side-effects land: the
 * user row is gone (cascading sessions, accounts, session
 * attestation), and any pre-existing device ACL grants owned by the
 * user are revoked with the per-slug revision counter ticked.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const DELETE_URL = `http://localhost${ACCOUNT_DELETE_PATH}`;
const [trustedOrigin] = env.TRUSTED_ORIGINS;
if (trustedOrigin === undefined) {
  throw new Error('env.TRUSTED_ORIGINS must contain at least one entry');
}

const errorBodyShape = z.object({
  ok: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
});

const successBodyShape = z.object({
  ok: z.literal(true),
  data: z.object({ deleted: z.literal(true) }),
});

const verifyResponseShape = z.object({
  session: z.looseObject({ id: z.string().min(1) }),
  user: z.looseObject({ id: z.string().min(1) }),
  token: z.string().min(1),
});

const randomEmail = (prefix: string): string =>
  `${prefix}-${randomBytes(6).toString('hex')}@example.com`;

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
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
  readonly userId: string;
  readonly sessionId: string;
  readonly bearer: string;
}

const signIn = async (
  auth: ReturnType<typeof createAuth>,
  delivery: RecordingDelivery,
  device: TestDeviceKey,
  clockNow: bigint,
): Promise<SignedInFixture> => {
  const email = randomEmail('delete');
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
  const payload = verifyResponseShape.parse(await verifyResponse.json());

  const bearer = verifyResponse.headers.get('set-auth-token');
  if (bearer === null || bearer.length === 0) {
    throw new Error('expected set-auth-token header on verify response');
  }

  return { email, userId: payload.user.id, sessionId: payload.session.id, bearer };
};

describe('account-deletion route: enforcement', () => {
  const fixedNow = 1_800_000_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let deleteHandler: (request: Request) => Promise<Response>;

  const freshDeleteHeader = (timestamp: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'deleteAccount', timestamp },
    });

  const headerWithBinding = (binding: AttestationBinding): string =>
    buildSignedAttestationHeader({ deviceKey: device, binding });

  const call = async (
    method: string,
    headers: Record<string, string>,
  ): Promise<{ response: Response; body: unknown }> => {
    const response = await deleteHandler(new Request(DELETE_URL, { method, headers }));
    const text = await response.text();
    const body: unknown = text.length > 0 ? JSON.parse(text) : null;
    return { response, body };
  };

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    deleteHandler = buildAccountDeleteRoute({ auth, nowSeconds: clock.now });
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  test('method not allowed on GET returns 405 with Allow header', async () => {
    const { response } = await call('GET', {});
    expect(response.status).toBe(405);
    expect(response.headers.get('Allow')).toBe('POST');
  });

  test('missing bearer → 401 SESSION_REQUIRED', async () => {
    const { response, body } = await call('POST', {
      [ATTESTATION_HEADER_NAME]: freshDeleteHeader(),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');
  });

  describe('binding-tag enforcement', () => {
    let fixture: SignedInFixture;

    beforeAll(async () => {
      clock.set(fixedNow);
      fixture = await signIn(auth, delivery, device, fixedNow);
    });

    afterAll(async () => {
      await clearEmail(fixture.email);
    });

    test('api: binding is refused — a universal-api signature must NOT satisfy delete-account', async () => {
      const header = headerWithBinding({ tag: 'api', timestamp: fixedNow });
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: header,
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');

      const rows = await db.select({ id: user.id }).from(user).where(eq(user.id, fixture.userId));
      expect(rows.length).toBe(1);
    });

    test('out: (sign-out) binding is refused', async () => {
      const header = headerWithBinding({ tag: 'signOut', timestamp: fixedNow });
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: header,
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
    });

    test('req: binding is refused', async () => {
      const header = headerWithBinding({ tag: 'request', timestamp: fixedNow });
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: header,
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
    });
  });

  describe('signature and skew enforcement', () => {
    let fixture: SignedInFixture;

    beforeAll(async () => {
      clock.set(fixedNow);
      fixture = await signIn(auth, delivery, device, fixedNow);
    });

    afterAll(async () => {
      await clearEmail(fixture.email);
    });

    test('attacker SE key — del: signature under the wrong key → 401 ATTESTATION_SIGNATURE_INVALID', async () => {
      const attacker = createTestDeviceKey();
      const header = buildSignedAttestationHeader({
        deviceKey: attacker,
        binding: { tag: 'deleteAccount', timestamp: fixedNow },
      });
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: header,
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SIGNATURE_INVALID');

      const rows = await db.select({ id: user.id }).from(user).where(eq(user.id, fixture.userId));
      expect(rows.length).toBe(1);
    });

    test('ancient timestamp → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
      const header = freshDeleteHeader(fixedNow - ATTESTATION_SKEW_SECONDS - 1n);
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: header,
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    });
  });

  describe('happy path with database side-effects', () => {
    let fixture: SignedInFixture;
    const deviceSlug = `test-device-${randomBytes(4).toString('hex')}`;

    beforeAll(async () => {
      clock.set(fixedNow);
      fixture = await signIn(auth, delivery, device, fixedNow);

      // Seed an active ACL grant for this user so the delete path
      // has something to revoke. The grant does not need a matching
      // `device` row — the ACL tables are orthogonal to the fleet
      // registration schema for this test's purposes.
      const now = new Date(Number(fixedNow * 1000n));
      await db.insert(deviceAclRevision).values({
        deviceSlug,
        revision: 1,
        updatedAt: now,
      });
      await db.insert(deviceAccessGrant).values({
        id: randomUUID(),
        deviceSlug,
        userSpkiB64: 'test-user-spki',
        userId: fixture.userId,
        grantedAt: now,
        revokedAt: null,
        revision: 1,
      });
    });

    afterAll(async () => {
      // Clean up the synthetic ACL rows in case the test was skipped
      // before the delete handler ran; ``device_access_grant.userId``
      // is ON DELETE SET NULL so rows survive a user delete.
      await db.delete(deviceAccessGrant).where(eq(deviceAccessGrant.deviceSlug, deviceSlug));
      await db.delete(deviceAclRevision).where(eq(deviceAclRevision.deviceSlug, deviceSlug));
      await clearEmail(fixture.email);
    });

    test('del: binding + valid signature → 200 { deleted: true } and wipes the user row', async () => {
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: freshDeleteHeader(),
      });
      expect(response.status).toBe(200);
      const parsed = successBodyShape.parse(body);
      expect(parsed.data.deleted).toBe(true);

      const userRows = await db
        .select({ id: user.id })
        .from(user)
        .where(eq(user.id, fixture.userId));
      expect(userRows.length).toBe(0);

      // Session cascade is implicit via `session.user_id` → `user`
      // FK with ON DELETE CASCADE. Verify the session row is gone so
      // a regression in the schema is caught here.
      const sessionRows = await db
        .select({ id: session.id })
        .from(session)
        .where(eq(session.id, fixture.sessionId));
      expect(sessionRows.length).toBe(0);

      // Grant ACL revocation: the seeded row must have `revokedAt`
      // set and the device's revision counter must have ticked
      // beyond the seeded starting value of 1.
      const grantRows = await db
        .select({
          revokedAt: deviceAccessGrant.revokedAt,
          deviceSlug: deviceAccessGrant.deviceSlug,
        })
        .from(deviceAccessGrant)
        .where(
          and(
            eq(deviceAccessGrant.deviceSlug, deviceSlug),
            eq(deviceAccessGrant.userSpkiB64, 'test-user-spki'),
          ),
        );
      expect(grantRows.length).toBe(1);
      expect(grantRows[0]?.revokedAt).not.toBeNull();

      const revisionRows = await db
        .select({ revision: deviceAclRevision.revision })
        .from(deviceAclRevision)
        .where(eq(deviceAclRevision.deviceSlug, deviceSlug));
      expect(revisionRows[0]?.revision).toBeGreaterThan(1);
    });

    test('second delete with a stale bearer → 401 SESSION_REQUIRED (user is gone)', async () => {
      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: freshDeleteHeader(),
      });
      expect(response.status).toBe(401);
      expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');
    });
  });

  describe('cleanup: no active grants remain for a deleted user', () => {
    test('deleting a user with no seeded grants still succeeds', async () => {
      clock.set(fixedNow);
      const fixture = await signIn(auth, delivery, device, fixedNow);

      const { response, body } = await call('POST', {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: freshDeleteHeader(),
      });
      expect(response.status).toBe(200);
      const parsed = successBodyShape.parse(body);
      expect(parsed.data.deleted).toBe(true);

      // Redundant sanity: no orphan grant rows survive by mistake.
      const remaining = await db
        .select({ id: deviceAccessGrant.id })
        .from(deviceAccessGrant)
        .where(
          and(eq(deviceAccessGrant.userId, fixture.userId), isNull(deviceAccessGrant.revokedAt)),
        );
      expect(remaining.length).toBe(0);

      await clearEmail(fixture.email);
    });
  });
});
