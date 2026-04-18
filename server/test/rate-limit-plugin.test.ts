import { randomBytes } from 'node:crypto';
import { beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { emailRateLimit, rateLimit, user } from '~/db/schema.ts';
import { ATTESTATION_HEADER_NAME } from '~/lib/attestation-plugin.ts';
import { AUTH_BASE_PATH, createAuth } from '~/lib/auth.ts';
import { db } from '~/lib/db.ts';
import { env } from '~/lib/env.ts';
import type { MagicLinkDelivery, MagicLinkEmailPayload } from '~/lib/magic-link.ts';
import {
  EMAIL_RATE_LIMIT_MAX,
  EMAIL_RATE_LIMIT_WINDOW_SECONDS,
  hashEmailForBucket,
} from '~/lib/rate-limit.ts';
import { uniqueClientIp, uniqueClientIpHeader } from './support/client-ip.ts';
import type { TestDeviceKey } from './support/signed-attestation.ts';
import { buildSignedAttestationHeader, createTestDeviceKey } from './support/signed-attestation.ts';

/**
 * End-to-end coverage for the per-email rate-limit plugin and its
 * interplay with the attestation gate, the magic-link plugin, and the
 * built-in per-(IP, path) limiter.
 *
 * Primary invariant under test: a rate-limited request returns
 * a byte-identical 200 `{ status: true }` response and does NOT
 * invoke `sendMagicLink`. That is the enumeration-resistance contract.
 *
 * Secondary invariants:
 *
 * 1. Attestation runs BEFORE rate limiting. A bad attestation 401s
 *    with no rate-limit row written. A valid but captured attestation
 *    still lands in the bucket.
 * 2. Buckets are keyed per-normalized-email — case variants collide,
 *    distinct emails do not.
 * 3. Windows reset atomically — after `EMAIL_RATE_LIMIT_WINDOW_SECONDS`
 *    of cooldown, the same email is accepted again.
 * 4. Per-IP 429 still fires independently of per-email. A single IP
 *    that bursts past the sign-in rule catches a 429; the email
 *    bucket for that address does NOT double-count rejected requests.
 */

const SIGN_IN_URL = `http://localhost${AUTH_BASE_PATH}/sign-in/magic-link`;
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

  public clear(): void {
    this.calls.length = 0;
  }
}

const randomEmail = (prefix: string): string =>
  `${prefix}-${randomBytes(6).toString('hex')}@rate-limit.example`;

const clearEmail = async (email: string): Promise<void> => {
  const rows = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
  await Promise.all(
    rows.map(async (row) => {
      await db.delete(user).where(eq(user.id, row.id));
    }),
  );
};

const clearEmailBucket = async (email: string): Promise<void> => {
  const emailHash = hashEmailForBucket(email, env.BETTER_AUTH_SECRET);
  await db.delete(emailRateLimit).where(eq(emailRateLimit.emailHash, emailHash));
};

const currentUnixSeconds = (): bigint => BigInt(Math.floor(Date.now() / 1000));

const reqAttestationHeader = (device: TestDeviceKey): string =>
  buildSignedAttestationHeader({
    deviceKey: device,
    binding: { tag: 'request', timestamp: currentUnixSeconds() },
  });

interface PostOpts {
  readonly email: string;
  readonly device: TestDeviceKey;
  readonly auth: ReturnType<typeof createAuth>;
  readonly forwardedFor?: string;
  readonly attestationHeader?: string;
  readonly skipAttestation?: boolean;
}

const postSignIn = async (opts: PostOpts): Promise<{ response: Response; body: unknown }> => {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Origin: trustedOrigin,
  };
  if (opts.skipAttestation !== true) {
    headers[ATTESTATION_HEADER_NAME] = opts.attestationHeader ?? reqAttestationHeader(opts.device);
  }
  // When a caller pins an IP, use it — that's how per-IP tests
  // exercise the built-in limiter. Default to a fresh random IP so
  // the per-email tests do not accidentally trip the per-IP rule
  // while they're iterating on a single address.
  if (opts.forwardedFor === undefined) {
    Object.assign(headers, uniqueClientIpHeader());
  } else {
    headers['X-Forwarded-For'] = opts.forwardedFor;
  }

  const response = await opts.auth.handler(
    new Request(SIGN_IN_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ email: opts.email }),
    }),
  );
  const text = await response.text();
  const parsed: unknown = text.length > 0 ? JSON.parse(text) : null;
  return { response, body: parsed };
};

const successBodyShape = z.strictObject({ status: z.literal(true) });

/**
 * The enumeration-resistance contract in one place. A swallowed
 * request and a real send are indistinguishable on every observable
 * axis the client can see:
 *
 * - status = 200
 * - Content-Type = application/json (case-insensitive)
 * - body = { status: true } (exact JSON, no extra fields)
 *
 * Assertions folded into a helper so every test that expects the
 * swallow path checks all three axes, not just status.
 */
const expectIdenticalSuccess = async (response: Response, body: unknown): Promise<void> => {
  expect(response.status).toBe(200);
  expect(response.headers.get('Content-Type')?.toLowerCase().startsWith('application/json')).toBe(
    true,
  );
  const parsed = successBodyShape.parse(body);
  expect(parsed.status).toBe(true);
  // The body should contain no additional fields (strictObject shape
  // rejects extras). Byte-identity with a real success response is
  // the only way enumeration stays sealed.
  await Promise.resolve();
};

describe('rate-limit plugin: enumeration-resistant silent swallow', () => {
  let delivery: RecordingDelivery;
  let device: TestDeviceKey;
  let auth: ReturnType<typeof createAuth>;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    device = createTestDeviceKey();
    auth = createAuth({ magicLinkDelivery: delivery });
  });

  beforeEach(() => {
    delivery.clear();
  });

  test('first EMAIL_RATE_LIMIT_MAX requests fire delivery; the next one is swallowed with identical 200', async () => {
    const email = randomEmail('swallow');
    await clearEmail(email);
    await clearEmailBucket(email);

    const withinBudget = [];
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      // Sequential by design — we're testing the count transition,
      // and pool-based concurrency would land all rows in one window
      // without observable ordering. `no-await-in-loop` is off by
      // intent for these test files.
      // eslint-disable-next-line no-await-in-loop
      const outcome = await postSignIn({ email, device, auth });
      withinBudget.push(outcome);
    }

    for (const { response, body } of withinBudget) {
      // eslint-disable-next-line no-await-in-loop
      await expectIdenticalSuccess(response, body);
    }
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // One more from the SAME IP would also trip the per-IP cap
    // depending on the test file's prior traffic; rotate IPs so
    // the swallow below is definitely email-driven, not IP-driven.
    const overBudget = await postSignIn({ email, device, auth });
    await expectIdenticalSuccess(overBudget.response, overBudget.body);
    // Delivery count did NOT advance — the swallow prevented
    // `sendMagicLink` from running.
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    await clearEmail(email);
    await clearEmailBucket(email);
  });

  test('case-variant emails share one bucket', async () => {
    const email = randomEmail('case');
    await clearEmail(email);
    await clearEmail(email.toUpperCase());
    await clearEmailBucket(email);

    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      await postSignIn({ email, device, auth });
    }
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // Upper-case variant — same bucket after normalization, so this
    // must be swallowed. Send a capitalized form AND extra whitespace
    // to make the normalization assertion unambiguous.
    const { response, body } = await postSignIn({
      email: `  ${email.toUpperCase()}  `,
      device,
      auth,
    });
    await expectIdenticalSuccess(response, body);
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    await clearEmail(email);
    await clearEmail(email.toUpperCase());
    await clearEmail(email.trim().toLowerCase());
    await clearEmailBucket(email);
  });

  test('distinct emails have independent budgets', async () => {
    const emailA = randomEmail('iso-a');
    const emailB = randomEmail('iso-b');
    await Promise.all([
      clearEmail(emailA),
      clearEmail(emailB),
      clearEmailBucket(emailA),
      clearEmailBucket(emailB),
    ]);

    // Burn A's entire budget.
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      await postSignIn({ email: emailA, device, auth });
    }
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // A is now over-budget — swallow.
    const overA = await postSignIn({ email: emailA, device, auth });
    await expectIdenticalSuccess(overA.response, overA.body);
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // B is a fresh bucket — delivery must fire.
    const firstB = await postSignIn({ email: emailB, device, auth });
    await expectIdenticalSuccess(firstB.response, firstB.body);
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX + 1);

    await Promise.all([
      clearEmail(emailA),
      clearEmail(emailB),
      clearEmailBucket(emailA),
      clearEmailBucket(emailB),
    ]);
  });

  test('swallowed request does not persist a user or verification row', async () => {
    const email = randomEmail('no-side-effect');
    await clearEmail(email);
    await clearEmailBucket(email);

    // Burn budget.
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      await postSignIn({ email, device, auth });
    }
    const afterBurn = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
    const countAfterBurn = afterBurn.length;

    // Swallowed request must NOT alter user-space state — neither a
    // fresh user nor a verification token should appear. A regression
    // that let the plugin run after the swallow (instead of short-
    // circuiting) would fail this test, because
    // `internalAdapter.createVerificationValue` fires inside the
    // magic-link endpoint handler.
    await postSignIn({ email, device, auth });

    const afterSwallow = await db.select({ id: user.id }).from(user).where(eq(user.email, email));
    expect(afterSwallow.length).toBe(countAfterBurn);

    await clearEmail(email);
    await clearEmailBucket(email);
  });
});

describe('rate-limit plugin: ordering with the attestation gate', () => {
  let delivery: RecordingDelivery;
  let device: TestDeviceKey;
  let auth: ReturnType<typeof createAuth>;

  beforeAll(() => {
    delivery = new RecordingDelivery();
    device = createTestDeviceKey();
    auth = createAuth({ magicLinkDelivery: delivery });
  });

  beforeEach(() => {
    delivery.clear();
  });

  test('missing attestation rejects with 401 ATTESTATION_REQUIRED before any bucket row is written', async () => {
    const email = randomEmail('no-attest');
    await clearEmail(email);
    await clearEmailBucket(email);

    // Attempt a sign-in with NO attestation header. The attestation
    // plugin's before-hook must short-circuit first; the rate-limit
    // plugin's before-hook must not touch the bucket store.
    const { response, body } = await postSignIn({ email, device, auth, skipAttestation: true });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_REQUIRED');
    expect(delivery.callCount()).toBe(0);

    // Verify the bucket ledger is empty for this email. A regression
    // that ran rate-limit BEFORE attestation would have left a row
    // behind here.
    const bucketKey = hashEmailForBucket(email, env.BETTER_AUTH_SECRET);
    const rows = await db
      .select()
      .from(emailRateLimit)
      .where(eq(emailRateLimit.emailHash, bucketKey));
    expect(rows).toHaveLength(0);

    await clearEmail(email);
    await clearEmailBucket(email);
  });

  test('wrong binding tag rejects with 401 ATTESTATION_BINDING_MISMATCH before any bucket row is written', async () => {
    const email = randomEmail('wrong-tag');
    await clearEmail(email);
    await clearEmailBucket(email);

    const misboundHeader = buildSignedAttestationHeader({
      deviceKey: device,
      binding: { tag: 'social', rawNonce: 'raw' },
    });
    const { response, body } = await postSignIn({
      email,
      device,
      auth,
      attestationHeader: misboundHeader,
    });
    expect(response.status).toBe(401);
    expect(errorBodyShape.parse(body).code).toBe('ATTESTATION_BINDING_MISMATCH');
    expect(delivery.callCount()).toBe(0);

    const bucketKey = hashEmailForBucket(email, env.BETTER_AUTH_SECRET);
    const rows = await db
      .select()
      .from(emailRateLimit)
      .where(eq(emailRateLimit.emailHash, bucketKey));
    expect(rows).toHaveLength(0);

    await clearEmail(email);
    await clearEmailBucket(email);
  });
});

describe('rate-limit plugin: window reset via injected clock', () => {
  test('after EMAIL_RATE_LIMIT_WINDOW_SECONDS of cooldown, the same email is accepted again', async () => {
    const delivery = new RecordingDelivery();
    const device = createTestDeviceKey();
    let now = new Date('2026-04-17T21:00:00Z');
    const auth = createAuth({
      magicLinkDelivery: delivery,
      rateLimitNowDate: () => now,
    });
    const email = randomEmail('reset');
    await clearEmail(email);
    await clearEmailBucket(email);

    // Burn the budget at tStart.
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      await postSignIn({ email, device, auth });
    }
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // One extra inside the window — swallow.
    const swallowed = await postSignIn({ email, device, auth });
    await expectIdenticalSuccess(swallowed.response, swallowed.body);
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX);

    // Advance the injected clock past the window. The next acquire's
    // CASE predicate fires the reset branch; a fresh send is allowed.
    now = new Date(now.getTime() + (EMAIL_RATE_LIMIT_WINDOW_SECONDS + 1) * 1000);
    const afterReset = await postSignIn({ email, device, auth });
    await expectIdenticalSuccess(afterReset.response, afterReset.body);
    expect(delivery.callCount()).toBe(EMAIL_RATE_LIMIT_MAX + 1);

    await clearEmail(email);
    await clearEmailBucket(email);
  });
});

describe('rate-limit plugin: per-IP cooldown (built-in)', () => {
  test('a single IP bursting past the sign-in rule is rejected with 429', async () => {
    const delivery = new RecordingDelivery();
    const device = createTestDeviceKey();
    const auth = createAuth({ magicLinkDelivery: delivery });
    const stickyIp = uniqueClientIp();
    await db.delete(rateLimit).where(eq(rateLimit.key, `${stickyIp}|/sign-in/magic-link`));

    // Fire more than the per-IP sign-in max (`SIGN_IN_RATE_LIMIT.max`
    // in `auth.ts`, currently 10 / 60s). Using a unique email per
    // call isolates the per-email budget so the rejection is unam-
    // biguously the per-IP limiter — a single-email run would hit
    // the per-email swallow first on the 4th call.
    const perIpMaxCap = 10;
    const overIpCap = perIpMaxCap + 3;
    const statuses: number[] = [];
    for (let index = 0; index < overIpCap; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      const { response } = await postSignIn({
        email: randomEmail(`ip-burst-${index}`),
        device,
        auth,
        forwardedFor: stickyIp,
      });
      statuses.push(response.status);
    }

    // First `perIpMaxCap` within budget, remainder over.
    const inBudget = statuses.slice(0, perIpMaxCap);
    const overBudget = statuses.slice(perIpMaxCap);
    expect(inBudget.every((status) => status === 200)).toBe(true);
    expect(overBudget.every((status) => status === 429)).toBe(true);

    await db.delete(rateLimit).where(eq(rateLimit.key, `${stickyIp}|/sign-in/magic-link`));
  });

  test('a 429 response does NOT advance the per-email bucket count', async () => {
    // Rate-limited-at-the-IP requests are rejected by the built-in
    // limiter's `onRequest` hook, which fires BEFORE plugin hooks;
    // the rate-limit plugin's before-hook never runs. The email
    // bucket must therefore not increment for these calls. If it
    // did, legitimate users downstream of a shared NAT getting
    // their addresses 429'd for IP reasons would have their own
    // per-email counters burned by a neighbor's traffic.
    const delivery = new RecordingDelivery();
    const device = createTestDeviceKey();
    const auth = createAuth({ magicLinkDelivery: delivery });
    const stickyIp = uniqueClientIp();
    await db.delete(rateLimit).where(eq(rateLimit.key, `${stickyIp}|/sign-in/magic-link`));

    const email = randomEmail('ip-429-bucket');
    await clearEmail(email);
    await clearEmailBucket(email);

    // Saturate the per-IP limiter with OTHER emails.
    const perIpMaxCap = 10;
    for (let index = 0; index < perIpMaxCap; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      await postSignIn({
        email: randomEmail(`ip-saturate-${index}`),
        device,
        auth,
        forwardedFor: stickyIp,
      });
    }

    // Now fire the target email from the same saturated IP. The
    // request is rejected with 429 before the rate-limit plugin
    // touches the email bucket.
    const { response } = await postSignIn({ email, device, auth, forwardedFor: stickyIp });
    expect(response.status).toBe(429);

    const bucketKey = hashEmailForBucket(email, env.BETTER_AUTH_SECRET);
    const rows = await db
      .select()
      .from(emailRateLimit)
      .where(eq(emailRateLimit.emailHash, bucketKey));
    expect(rows).toHaveLength(0);

    await clearEmail(email);
    await clearEmailBucket(email);
    await db.delete(rateLimit).where(eq(rateLimit.key, `${stickyIp}|/sign-in/magic-link`));
  });
});
