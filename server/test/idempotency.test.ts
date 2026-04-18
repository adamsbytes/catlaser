import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import { idempotencyRecord, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import type { NowSecondsFn } from '~/lib/attestation-skew.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { IdempotentRouteHandler } from '~/lib/idempotency.ts';
import {
  IDEMPOTENCY_HEADER_NAME,
  IDEMPOTENCY_TTL_SECONDS,
  withIdempotentAttestedSession,
} from '~/lib/idempotency.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import { uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the idempotency middleware — the write-replay
 * defence that closes the 60s residual window around per-request
 * attestation.
 *
 * These tests compose the full pipeline: magic-link sign-in under a frozen
 * attestation clock, bearer extraction, then mutating calls through
 * `withIdempotentAttestedSession`. Every rejection path is exercised with
 * a concrete cause (missing key, malformed key, same key + different
 * body, captured attestation replay, pending concurrent duplicate) so a
 * regression in any individual check surfaces in isolation. Happy-path
 * calls document the invariants that the full gate accepts a real
 * attested request and caches the response for replay without
 * re-executing the handler.
 *
 * Key invariants under test:
 *
 * 1. The attestation gate runs BEFORE the idempotency gate. A bad bearer
 *    or missing attestation never lands a pending lease.
 * 2. First execution caches the response; a replay with identical
 *    `(method, pathname, body)` returns the cached response and does NOT
 *    re-invoke the handler.
 * 3. A replay with the same key but different body is rejected as
 *    `IDEMPOTENCY_KEY_MISMATCH` — never silently overwrites the cache.
 * 4. Pending leases reject with `IDEMPOTENCY_REQUEST_IN_PROGRESS`.
 * 5. Expired leases are atomically replaced by the acquire path.
 * 6. 4xx responses are cached (deterministic rejections); 5xx and handler
 *    exceptions release the lease so the client can retry.
 * 7. Keys are scoped to `(session_id, key)`; different sessions with the
 *    same key are independent.
 * 8. Session deletion cascades and wipes every idempotency record.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
const VERIFY_URL_BASE = `http://localhost${AUTH_BASE_PATH}/magic-link/verify`;
const MUTATING_URL = 'http://localhost/api/v1/idempotency-smoke';
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
  data: z.looseObject({}),
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
 * A `nowSeconds` source whose value the test can advance mid-suite. Used
 * to drive signed-in state (during setup) and attestation timestamps
 * under the same frozen clock the middleware sees.
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
 * return the bearer + session id. Any setup failure throws, so dependent
 * tests cannot silently run against stale state.
 */
const signIn = async (
  auth: ReturnType<typeof createAuth>,
  delivery: RecordingDelivery,
  device: TestDeviceKey,
  clockNow: bigint,
): Promise<SignedInFixture> => {
  const email = randomEmail('idemp');
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

/**
 * Build a handler factory that also exposes a call counter so tests can
 * assert that a cached replay never re-invokes the handler.
 */
interface InstrumentedHandler {
  readonly handler: IdempotentRouteHandler;
  invocations: number;
  readonly bodies: unknown[];
}

const instrumentedHandler = (
  build: (invocation: number, request: Request) => Response | Promise<Response>,
): InstrumentedHandler => {
  const record: InstrumentedHandler = {
    handler: async (request) => {
      record.invocations += 1;
      const text = await request.text();
      record.bodies.push(text.length === 0 ? null : JSON.parse(text));
      return await build(record.invocations, new Request(request.url, { method: request.method }));
    },
    invocations: 0,
    bodies: [],
  };
  return record;
};

const jsonSuccessResponse = (data: Record<string, unknown>): Response =>
  Response.json({ ok: true, data }, { status: 200 });

const jsonErrorResponse = (code: string, status: number): Response =>
  Response.json({ ok: false, error: { code, message: code } }, { status });

describe('idempotency middleware: gate enforcement', () => {
  const fixedNow = 1_800_700_000n;
  const clock = mutableClock(fixedNow);
  let delivery: RecordingDelivery;
  let auth: ReturnType<typeof createAuth>;
  let device: TestDeviceKey;
  let fixture: SignedInFixture;

  const apiHeader = (timestamp: bigint = fixedNow): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp },
    });

  beforeAll(async () => {
    delivery = new RecordingDelivery();
    auth = createAuth({
      magicLinkDelivery: delivery,
      attestationNowSeconds: clock.now,
    });
    device = createTestDeviceKey();
    clock.set(fixedNow);
    fixture = await signIn(auth, delivery, device, fixedNow);
  });

  afterAll(async () => {
    await clearEmail(fixture.email);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  const wrap = (h: IdempotentRouteHandler): ((request: Request) => Promise<Response>) =>
    withIdempotentAttestedSession(h, { auth, nowSeconds: clock.now });

  const defaultHeaders = (extra: Record<string, string> = {}): Record<string, string> => ({
    Authorization: `Bearer ${fixture.bearer}`,
    [ATTESTATION_HEADER_NAME]: apiHeader(),
    'Content-Type': 'application/json',
    ...extra,
  });

  const post = async (
    gate: (request: Request) => Promise<Response>,
    headers: Record<string, string>,
    body?: unknown,
  ): Promise<{ response: Response; body: unknown; rawText: string }> => {
    const requestBody = body === undefined ? { op: 'noop' } : body;
    const response = await gate(
      new Request(MUTATING_URL, {
        method: 'POST',
        headers,
        body: JSON.stringify(requestBody),
      }),
    );
    const rawText = await response.text();
    const contentType = response.headers.get('Content-Type') ?? '';
    const isJson = contentType.toLowerCase().startsWith('application/json');
    const parsed: unknown = rawText.length > 0 && isJson ? JSON.parse(rawText) : null;
    return { response, body: parsed, rawText };
  };

  test('happy path: bearer + fresh api: attestation + valid key → 200 + lease persisted', async () => {
    const record = instrumentedHandler((invocation) =>
      jsonSuccessResponse({ invocation, ok: true }),
    );
    const gate = wrap(record.handler);
    const key = randomUUID();

    const { response, body } = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));

    expect(response.status).toBe(200);
    const parsed = successBodyShape.parse(body);
    expect(parsed.data).toMatchObject({ invocation: 1, ok: true });
    expect(record.invocations).toBe(1);

    const rows = await db
      .select()
      .from(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
    expect(rows).toHaveLength(1);
    const [row] = rows;
    if (row === undefined) {
      throw new Error('expected exactly one row');
    }
    expect(row.statusCode).toBe(200);
    // `Response.json` emits `application/json;charset=UTF-8`; pin the
    // MIME prefix without over-asserting the charset casing.
    expect(row.responseContentType?.toLowerCase().startsWith('application/json')).toBe(true);
    expect(row.responseBody).not.toBeNull();
    await db.delete(idempotencyRecord).where(eq(idempotencyRecord.id, row.id));
  });

  test('replay with identical (session, key, body) returns cached response without re-invoking handler', async () => {
    const record = instrumentedHandler((invocation) =>
      jsonSuccessResponse({ invocation, token: randomUUID() }),
    );
    const gate = wrap(record.handler);
    const key = randomUUID();
    const body = { op: 'cache-me', value: 42 };

    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), body);
    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), body);

    expect(first.response.status).toBe(200);
    expect(second.response.status).toBe(200);
    // Handler invoked exactly once — the second call is a cache replay.
    expect(record.invocations).toBe(1);
    // Response bodies byte-identical — replay reproduces the original.
    expect(second.body).toEqual(first.body);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('replay with same key but different body → 422 IDEMPOTENCY_KEY_MISMATCH and handler not re-invoked', async () => {
    const record = instrumentedHandler((invocation) => jsonSuccessResponse({ invocation }));
    const gate = wrap(record.handler);
    const key = randomUUID();

    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), {
      op: 'original',
    });
    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), {
      op: 'tampered',
    });

    expect(first.response.status).toBe(200);
    expect(second.response.status).toBe(422);
    expect(errorBodyShape.parse(second.body).error.code).toBe('IDEMPOTENCY_KEY_MISMATCH');
    expect(record.invocations).toBe(1);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('missing Idempotency-Key header → 400 IDEMPOTENCY_KEY_REQUIRED and handler not invoked', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);

    const { response, body } = await post(gate, defaultHeaders());

    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
    expect(record.invocations).toBe(0);
  });

  test('empty Idempotency-Key header → 400 IDEMPOTENCY_KEY_REQUIRED', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);

    const { response, body } = await post(
      gate,
      defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: '   ' }),
    );

    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
    expect(record.invocations).toBe(0);
  });

  test('non-UUID Idempotency-Key header → 400 IDEMPOTENCY_KEY_INVALID', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);

    const { response, body } = await post(
      gate,
      defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: 'not-a-uuid' }),
    );

    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    expect(record.invocations).toBe(0);
  });

  test('UUID with trailing garbage → 400 IDEMPOTENCY_KEY_INVALID', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);

    const { response, body } = await post(
      gate,
      defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: `${randomUUID()}-x` }),
    );

    expect(response.status).toBe(400);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_KEY_INVALID');
    expect(record.invocations).toBe(0);
  });

  test('missing bearer → 401 SESSION_REQUIRED before idempotency gate fires', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);
    const key = randomUUID();

    const { response, body } = await post(gate, {
      [ATTESTATION_HEADER_NAME]: apiHeader(),
      [IDEMPOTENCY_HEADER_NAME]: key,
      'Content-Type': 'application/json',
    });

    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('SESSION_REQUIRED');
    expect(record.invocations).toBe(0);
    // Attestation gate rejected before any lease was written.
    const rows = await db
      .select()
      .from(idempotencyRecord)
      .where(eq(idempotencyRecord.idempotencyKey, key));
    expect(rows).toHaveLength(0);
  });

  test('missing attestation → 401 ATTESTATION_REQUIRED before idempotency gate fires', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);
    const key = randomUUID();

    const { response, body } = await post(gate, {
      Authorization: `Bearer ${fixture.bearer}`,
      [IDEMPOTENCY_HEADER_NAME]: key,
      'Content-Type': 'application/json',
    });

    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_REQUIRED');
    expect(record.invocations).toBe(0);
    const rows = await db
      .select()
      .from(idempotencyRecord)
      .where(eq(idempotencyRecord.idempotencyKey, key));
    expect(rows).toHaveLength(0);
  });

  test('captured-attestation replay is rejected by the attestation gate, idempotency never fires', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);
    const key = randomUUID();

    // Drive the clock forward past the skew window so the api: timestamp
    // is stale. Attestation gate must reject before the idempotency
    // middleware ever touches the store.
    clock.set(fixedNow + 120n);
    const { response, body } = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    clock.set(fixedNow);

    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).error.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(record.invocations).toBe(0);
    const rows = await db
      .select()
      .from(idempotencyRecord)
      .where(eq(idempotencyRecord.idempotencyKey, key));
    expect(rows).toHaveLength(0);
  });

  test('pending lease from a concurrent duplicate → 409 IDEMPOTENCY_REQUEST_IN_PROGRESS', async () => {
    const record = instrumentedHandler(() => jsonSuccessResponse({}));
    const gate = wrap(record.handler);
    const key = randomUUID();
    const bodyText = JSON.stringify({ op: 'noop' });

    // Seed a pending lease the way the middleware would — same request
    // hash, same session, null response fields. A caller hitting the gate
    // now must see the pending state and 409, not re-execute the handler.
    const requestHash = createHash('sha256')
      .update(`POST\n/api/v1/idempotency-smoke\n${bodyText}`, 'utf8')
      .digest('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    const now = new Date();
    await db.insert(idempotencyRecord).values({
      id: randomUUID(),
      sessionId: fixture.sessionId,
      idempotencyKey: key,
      requestHash,
      statusCode: null,
      responseBody: null,
      responseContentType: null,
      createdAt: now,
      expiresAt: new Date(now.getTime() + IDEMPOTENCY_TTL_SECONDS * 1000),
    });

    const { response, body } = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    expect(response.status).toBe(409);
    expect(errorBodyShape.parse(body).error.code).toBe('IDEMPOTENCY_REQUEST_IN_PROGRESS');
    expect(record.invocations).toBe(0);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('expired lease is atomically replaced; retry under same key re-executes', async () => {
    const record = instrumentedHandler((invocation) => jsonSuccessResponse({ invocation }));
    const gate = wrap(record.handler);
    const key = randomUUID();
    const body = { op: 'noop' };

    // First call runs and caches.
    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), body);
    expect(first.response.status).toBe(200);
    expect(record.invocations).toBe(1);

    // Force the stored row past its TTL. The acquire path's
    // `ON CONFLICT DO UPDATE … WHERE expires_at <= now` predicate must
    // take ownership of the expired row rather than serve stale cache.
    const stale = new Date(Date.now() - (IDEMPOTENCY_TTL_SECONDS + 1) * 1000);
    await db
      .update(idempotencyRecord)
      .set({ expiresAt: stale })
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );

    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }), body);
    expect(second.response.status).toBe(200);
    // Handler ran again — cache was not served from the expired row.
    expect(record.invocations).toBe(2);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('handler returning 4xx is cached and replayed verbatim', async () => {
    const record = instrumentedHandler(() => jsonErrorResponse('UNPROCESSABLE', 422));
    const gate = wrap(record.handler);
    const key = randomUUID();

    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));

    expect(first.response.status).toBe(422);
    expect(second.response.status).toBe(422);
    expect(errorBodyShape.parse(first.body).error.code).toBe('UNPROCESSABLE');
    expect(errorBodyShape.parse(second.body).error.code).toBe('UNPROCESSABLE');
    expect(record.invocations).toBe(1);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('handler returning 5xx releases the lease; retry re-executes', async () => {
    const record = instrumentedHandler((invocation) => {
      if (invocation === 1) {
        return jsonErrorResponse('INTERNAL', 500);
      }
      return jsonSuccessResponse({ invocation });
    });
    const gate = wrap(record.handler);
    const key = randomUUID();

    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    expect(first.response.status).toBe(500);
    // Lease was released on the 5xx — no cache row persists.
    const afterFirst = await db
      .select()
      .from(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
    expect(afterFirst).toHaveLength(0);

    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    expect(second.response.status).toBe(200);
    expect(record.invocations).toBe(2);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('handler throwing releases the lease; retry succeeds', async () => {
    const record = instrumentedHandler((invocation) => {
      if (invocation === 1) {
        throw new Error('boom');
      }
      return jsonSuccessResponse({ invocation });
    });
    const gate = wrap(record.handler);
    const key = randomUUID();

    let thrownMessage: string | undefined;
    try {
      await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    } catch (error) {
      thrownMessage = error instanceof Error ? error.message : String(error);
    }
    expect(thrownMessage).toBe('boom');
    const afterThrow = await db
      .select()
      .from(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
    expect(afterThrow).toHaveLength(0);

    const retry = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    expect(retry.response.status).toBe(200);
    expect(record.invocations).toBe(2);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });

  test('cached Content-Type is preserved across replay', async () => {
    const record = instrumentedHandler(
      () =>
        new Response('<hello/>', {
          status: 200,
          headers: { 'Content-Type': 'application/xml; charset=utf-8' },
        }),
    );
    const gate = wrap(record.handler);
    const key = randomUUID();

    const first = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));
    const second = await post(gate, defaultHeaders({ [IDEMPOTENCY_HEADER_NAME]: key }));

    expect(first.response.headers.get('Content-Type')).toBe('application/xml; charset=utf-8');
    expect(second.response.headers.get('Content-Type')).toBe('application/xml; charset=utf-8');
    // `post` has drained both response bodies into `first.rawText` and
    // `second.rawText`; the replay must byte-match the original and
    // the handler must only have run on the first call.
    expect(first.rawText).toBe('<hello/>');
    expect(second.rawText).toBe('<hello/>');
    expect(record.invocations).toBe(1);
    await db
      .delete(idempotencyRecord)
      .where(
        and(
          eq(idempotencyRecord.sessionId, fixture.sessionId),
          eq(idempotencyRecord.idempotencyKey, key),
        ),
      );
  });
});

describe('idempotency middleware: session isolation and cascade', () => {
  const fixedNow = 1_800_800_000n;
  const clock = mutableClock(fixedNow);
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
    clock.set(fixedNow);
  });

  beforeEach(() => {
    clock.set(fixedNow);
  });

  const apiHeader = (): string =>
    buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'api', timestamp: fixedNow },
    });

  test('two sessions with the same idempotency key run independently', async () => {
    const fixtureA = await signIn(auth, delivery, device, fixedNow);
    const fixtureB = await signIn(auth, delivery, device, fixedNow);
    try {
      const record = instrumentedHandler((invocation) => jsonSuccessResponse({ invocation }));
      const gate = withIdempotentAttestedSession(record.handler, {
        auth,
        nowSeconds: clock.now,
      });
      const key = randomUUID();
      const body = JSON.stringify({ op: 'noop' });
      const makeHeaders = (bearer: string): Record<string, string> => ({
        Authorization: `Bearer ${bearer}`,
        [ATTESTATION_HEADER_NAME]: apiHeader(),
        [IDEMPOTENCY_HEADER_NAME]: key,
        'Content-Type': 'application/json',
      });

      const responseA = await gate(
        new Request(MUTATING_URL, { method: 'POST', headers: makeHeaders(fixtureA.bearer), body }),
      );
      const responseB = await gate(
        new Request(MUTATING_URL, { method: 'POST', headers: makeHeaders(fixtureB.bearer), body }),
      );

      expect(responseA.status).toBe(200);
      expect(responseB.status).toBe(200);
      // Both sessions ran the handler — they do not share a ledger
      // entry even though the idempotency key bytes are identical.
      expect(record.invocations).toBe(2);

      const rows = await db
        .select()
        .from(idempotencyRecord)
        .where(eq(idempotencyRecord.idempotencyKey, key));
      expect(rows).toHaveLength(2);
      const sessions = rows.map((row) => row.sessionId).toSorted();
      expect(sessions).toEqual([fixtureA.sessionId, fixtureB.sessionId].toSorted());
    } finally {
      await clearEmail(fixtureA.email);
      await clearEmail(fixtureB.email);
    }
  });

  test('session delete cascades; owning idempotency rows are wiped', async () => {
    const fixture = await signIn(auth, delivery, device, fixedNow);
    try {
      const record = instrumentedHandler(() => jsonSuccessResponse({}));
      const gate = withIdempotentAttestedSession(record.handler, {
        auth,
        nowSeconds: clock.now,
      });
      const key = randomUUID();
      const headers: Record<string, string> = {
        Authorization: `Bearer ${fixture.bearer}`,
        [ATTESTATION_HEADER_NAME]: apiHeader(),
        [IDEMPOTENCY_HEADER_NAME]: key,
        'Content-Type': 'application/json',
      };

      const first = await gate(
        new Request(MUTATING_URL, {
          method: 'POST',
          headers,
          body: JSON.stringify({ op: 'cache-me' }),
        }),
      );
      expect(first.status).toBe(200);
      const beforeDelete = await db
        .select()
        .from(idempotencyRecord)
        .where(eq(idempotencyRecord.sessionId, fixture.sessionId));
      expect(beforeDelete).toHaveLength(1);

      // Deleting the user cascades to session and, from there, to
      // idempotency_record. The ledger must not outlive its owning
      // session — protected calls under a different session never
      // intersect this row, and the row is dead state otherwise.
      await clearEmail(fixture.email);

      const afterDelete = await db
        .select()
        .from(idempotencyRecord)
        .where(eq(idempotencyRecord.sessionId, fixture.sessionId));
      expect(afterDelete).toHaveLength(0);
    } finally {
      await clearEmail(fixture.email);
    }
  });
});
