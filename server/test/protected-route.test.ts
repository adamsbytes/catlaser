import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { sessionAttestation, user } from '~/db/schema.ts';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { ATTESTATION_SKEW_SECONDS } from '~/lib/attestation-skew.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { withAttestedSession } from '~/lib/protected-route.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the protected-route attestation middleware.
 *
 * These tests compose the full pipeline: magic-link sign-in under a
 * frozen clock, bearer extraction, then protected-route calls. Every
 * rejection path is exercised with a concrete cause (no attestation,
 * wrong binding, attacker key, stale timestamp) so a regression in any
 * individual check surfaces in isolation. Happy-path calls document the
 * invariant that the full gate (session + attestation + signature +
 * skew) accepts a real fresh attestation.
 *
 * Key invariant under test: signature verification runs against the
 * stored SPKI, not the wire SPKI. A captured bearer paired with a fresh
 * attestation signed under any other SE key is rejected, regardless of
 * what pk is on the wire.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const PROTECTED_URL = 'http://localhost/api/v1/protected-route-smoke';
const trustedOrigin = env.TRUSTED_ORIGINS[0] ?? 'http://localhost:3000';

const errorBodyShape = z.object({
  ok: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
  }),
});

const successBodyShape = z.object({
  ok: z.literal(true),
  data: z.object({
    id: z.string().min(1),
    email: z.string().min(1),
    emailVerified: z.boolean(),
  }),
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

/**
 * A `nowSeconds` source whose value the test can advance mid-suite.
 * Used to drive signed-in state (during setup) and skew-rejection state
 * (once tests start probing boundaries) from the same auth instance.
 */
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
}

/**
 * Drive a full magic-link sign-in under the suite's frozen clock and
 * return the bearer + session id. Any setup failure throws, so the
 * tests that depend on a signed-in state can't silently run against
 * stale state.
 */
const signIn = async (
  auth: ReturnType<typeof createAuth>,
  delivery: RecordingDelivery,
  device: TestDeviceKey,
  clockNow: bigint,
): Promise<SignedInFixture> => {
  const email = randomEmail('protected');
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

  return { email, bearer, sessionId: verifyPayload.session.id };
};

describe('protected-route middleware: gate enforcement', () => {
  const fixedNow = 1_800_000_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let attestedHandler: (request: Request) => Promise<Response>;
  let fixture: SignedInFixture;

  const freshApiHeader = (timestamp: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp },
    });

  const headerWithBinding = (binding: AttestationBinding): string =>
    buildSignedAttestationHeader({ deviceKey: device, binding });

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    // Handler returns the authenticated user — mirrors `GET /api/v1/me` but
    // is isolated under its own auth instance so the test clock governs
    // signing, verification, and protected-route enforcement together.
    attestedHandler = withAttestedSession(
      // eslint-disable-next-line @typescript-eslint/require-await
      async (_request, session) =>
        globalThis.Response.json(
          {
            ok: true,
            data: {
              id: session.user.id,
              email: session.user.email,
              emailVerified: session.user.emailVerified,
            },
          },
          { status: 200 },
        ),
      { auth, nowSeconds: clock.now },
    );

    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  const call = async (
    headers: Record<string, string>,
  ): Promise<{ response: Response; body: unknown }> => {
    const response = await attestedHandler(new Request(PROTECTED_URL, { method: 'GET', headers }));
    const text = await response.text();
    const body: unknown = text.length > 0 ? JSON.parse(text) : null;
    return { response, body };
  };

  test('happy path: valid bearer + fresh api: attestation returns the authenticated user', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(),
    });
    expect(response.status).toBe(200);
    const parsed = successBodyShape.parse(body);
    expect(parsed.data.email).toBe(fixture.email);
  });

  test('no bearer → 401 SESSION_REQUIRED', async () => {
    const { response, body } = await call({ [ATTESTATION_HEADER_NAME]: freshApiHeader() });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');
  });

  test('malformed bearer (no HMAC signature, requireSignature: true enforced upstream) → 401 SESSION_REQUIRED', async () => {
    const { response, body } = await call({
      Authorization: 'Bearer not-a-signed-token',
      [ATTESTATION_HEADER_NAME]: freshApiHeader(),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');
  });

  test('valid bearer + missing attestation header → 401 ATTESTATION_REQUIRED', async () => {
    const { response, body } = await call({ Authorization: `Bearer ${fixture.bearer}` });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_REQUIRED');
  });

  test('valid bearer + empty attestation header → 401 ATTESTATION_REQUIRED', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: '   ',
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_REQUIRED');
  });

  test('valid bearer + garbage attestation header → 401 ATTESTATION_INVALID', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: 'not@valid-base64',
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_INVALID');
  });

  test('valid bearer + req: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = headerWithBinding({ tag: 'request', timestamp: fixedNow });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('valid bearer + ver: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = headerWithBinding({ tag: 'verify', token: 'arbitrary-token' });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('valid bearer + sis: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = headerWithBinding({ tag: 'social', rawNonce: 'arbitrary-nonce' });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('valid bearer + out: binding → 401 ATTESTATION_BINDING_MISMATCH', async () => {
    const header = headerWithBinding({ tag: 'signOut', timestamp: fixedNow });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_BINDING_MISMATCH');
  });

  test('attacker SE key (fresh, fully-valid-shape api: attestation) → 401 ATTESTATION_SIGNATURE_INVALID', async () => {
    // The canonical "captured bearer" scenario: attacker holds the bearer
    // and produces a fresh `api:` header signed under THEIR SE key. Wire
    // sig and wire pk both match the attacker — but the stored SPKI
    // belongs to the legitimate device, so verify fails.
    const attacker = createTestDeviceKey();
    const header = buildSignedAttestationHeader({
      deviceKey: attacker,
      binding: { tag: 'api', timestamp: fixedNow },
    });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('swapping the wire pk does not influence verify (stored pk is load-bearing)', async () => {
    // Build a normal api: attestation signed by the legitimate device.
    // Then swap the wire pk to an unrelated (structurally valid) SPKI.
    // The middleware ignores the wire pk and verifies under the stored
    // key, so this MUST still succeed.
    const decoy = createTestDeviceKey();
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
      overridePublicKeySPKI: decoy.publicKeySPKI,
    });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(200);
    expect(successBodyShape.parse(body).data.email).toBe(fixture.email);
  });

  test('skew lower bound (now - 60s) is inclusive (accepts)', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(fixedNow - ATTESTATION_SKEW_SECONDS),
    });
    expect(response.status).toBe(200);
    expect(successBodyShape.parse(body).data.email).toBe(fixture.email);
  });

  test('skew upper bound (now + 60s) is inclusive (accepts)', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(fixedNow + ATTESTATION_SKEW_SECONDS),
    });
    expect(response.status).toBe(200);
    expect(successBodyShape.parse(body).data.email).toBe(fixture.email);
  });

  test('skew past lower bound (now - 61s) → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(fixedNow - ATTESTATION_SKEW_SECONDS - 1n),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('skew past upper bound (now + 61s) → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(fixedNow + ATTESTATION_SKEW_SECONDS + 1n),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('ancient timestamp (captured-attestation replay) → 401 ATTESTATION_SKEW_EXCEEDED', async () => {
    const ancient = fixedNow - ATTESTATION_SKEW_SECONDS * 1_000_000n;
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(ancient),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('SPKI-malformed wire pk is still handled — stored pk is what verifies, so passes', async () => {
    // The wire pk is ignored on stored-key verify; supplying a
    // structurally-malformed one that still survives header parsing
    // should not fail the gate. The header parser caps pk at >= 26
    // bytes, so we go just over the lower bound.
    const dud = new Uint8Array(30);
    dud[0] = 0x30;
    dud[1] = 0x28;
    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
      overridePublicKeySPKI: dud,
    });
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(200);
    expect(successBodyShape.parse(body).data.email).toBe(fixture.email);
  });

  test('clock advance past skew window invalidates a previously-valid attestation', async () => {
    // Build an attestation that is valid at fixedNow. Advance the clock
    // past the skew window. The same attestation is now stale and MUST
    // reject — documents that skew enforcement is re-evaluated per call,
    // not cached.
    const header = freshApiHeader(fixedNow);
    clock.set(fixedNow + ATTESTATION_SKEW_SECONDS + 5n);
    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: header,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
  });

  test('missing session_attestation row (e.g. schema regression) → 401 SESSION_ATTESTATION_MISSING', async () => {
    // Wipe the stored row to simulate a missing binding; every other
    // input stays valid. The middleware must refuse the call rather
    // than silently skipping the verify — doing otherwise inverts the
    // security posture. This test runs last in its suite because it
    // mutates the backing row.
    await db.delete(sessionAttestation).where(eq(sessionAttestation.sessionId, fixture.sessionId));

    const { response, body } = await call({
      Authorization: `Bearer ${fixture.bearer}`,
      [ATTESTATION_HEADER_NAME]: freshApiHeader(),
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_ATTESTATION_MISSING');
  });
});

describe('protected-route middleware: /api/v1/me integration', () => {
  const clock = mutableClock(1_800_500_000n);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
  });

  beforeEach(() => {
    delivery.reset();
  });

  test('a signed-in caller invoking /api/v1/me through withAttestedSession returns their user row', async () => {
    // Smoke-test the wiring the production server will use: create an
    // auth instance with a frozen clock, sign in, then compose
    // `withAttestedSession` against the standard /api/v1/me handler
    // shape. This mirrors what `src/routes/me.ts` does with the
    // module-level `auth` export — proving the wrapper composes
    // correctly against an arbitrary Auth instance, not just the
    // production singleton.
    const fixedNow = clock.now();
    const fixture = await signIn(auth, delivery, device, fixedNow);

    const meHandler = withAttestedSession(
      // eslint-disable-next-line @typescript-eslint/require-await
      async (_request, session) =>
        globalThis.Response.json(
          {
            ok: true,
            data: {
              id: session.user.id,
              email: session.user.email,
              emailVerified: session.user.emailVerified,
            },
          },
          { status: 200 },
        ),
      { auth, nowSeconds: clock.now },
    );

    const header = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
    });
    const response = await meHandler(
      new Request('http://localhost/api/v1/me', {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${fixture.bearer}`,
          [ATTESTATION_HEADER_NAME]: header,
        },
      }),
    );
    expect(response.status).toBe(200);
    const body = successBodyShape.parse(await response.json());
    expect(body.data.email).toBe(fixture.email);
    expect(body.data.id.length).toBeGreaterThan(0);

    await clearEmail(fixture.email);
  });
});
