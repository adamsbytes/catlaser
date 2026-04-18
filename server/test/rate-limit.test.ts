import { randomBytes } from 'node:crypto';
import { beforeEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import { emailRateLimit } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import {
  EMAIL_RATE_LIMIT_MAX,
  EMAIL_RATE_LIMIT_WINDOW_SECONDS,
  acquireEmailRateLimit,
  hashEmailForBucket,
  normalizeEmailForBucket,
} from '~/lib/rate-limit.ts';

/**
 * Module-level coverage for the per-email rate-limit acquire path.
 *
 * Integration-level tests that exercise the full magic-link flow live
 * in `rate-limit-plugin.test.ts`. This file pins the atomic-upsert
 * primitives that file builds on:
 *
 * 1. HMAC-over-normalized-email is deterministic, case-insensitive, and
 *    sensitive to the server secret.
 * 2. First acquire inserts count=1. Subsequent acquires within the
 *    window increment. Over-budget acquires return `allowed=false`
 *    without dropping the counter.
 * 3. An expired window is atomically replaced — the next acquire sees
 *    `requestCount=1` with a fresh `windowStartedAt`.
 * 4. Concurrent acquires serialize correctly on the unique constraint —
 *    the final count matches the number of issued acquires.
 *
 * Every test uses a fresh bucket key (random-bytes per test) so runs
 * are independent and re-runs do not carry state.
 */

const secret = 'test-rate-limit-secret-characters-padded-to-32-plus';

const freshBucketKey = (): string => `rl-test-${randomBytes(12).toString('hex')}`;

const deleteBucket = async (emailHash: string): Promise<void> => {
  await db.delete(emailRateLimit).where(eq(emailRateLimit.emailHash, emailHash));
};

const fixedClock = (now: Date): (() => Date) => {
  return () => now;
};

describe('rate-limit: email normalization + HMAC', () => {
  test('normalization lowercases and trims', () => {
    expect(normalizeEmailForBucket('  FOO@Example.COM  ')).toBe('foo@example.com');
  });

  test('hashEmailForBucket is deterministic for identical normalized inputs', () => {
    const a = hashEmailForBucket('user@example.com', secret);
    const b = hashEmailForBucket('user@example.com', secret);
    expect(a).toBe(b);
  });

  test('hashEmailForBucket collapses case variants onto the same bucket', () => {
    const a = hashEmailForBucket('User@Example.com', secret);
    const b = hashEmailForBucket('user@example.com', secret);
    expect(a).toBe(b);
  });

  test('hashEmailForBucket collapses whitespace variants onto the same bucket', () => {
    const a = hashEmailForBucket('  user@example.com\t', secret);
    const b = hashEmailForBucket('user@example.com', secret);
    expect(a).toBe(b);
  });

  test('hashEmailForBucket preserves plus-addressing distinctions', () => {
    // Treating plus-variants as the same bucket would silently merge
    // distinct user identities in systems that route sub-addresses
    // independently; leaving them separate is the correct default.
    const a = hashEmailForBucket('user+a@example.com', secret);
    const b = hashEmailForBucket('user+b@example.com', secret);
    const c = hashEmailForBucket('user@example.com', secret);
    expect(a).not.toBe(b);
    expect(a).not.toBe(c);
    expect(b).not.toBe(c);
  });

  test('hashEmailForBucket depends on the server secret', () => {
    const underA = hashEmailForBucket('user@example.com', 'secret-a-padded-to-at-least-32-chars');
    const underB = hashEmailForBucket('user@example.com', 'secret-b-padded-to-at-least-32-chars');
    expect(underA).not.toBe(underB);
  });

  test('hashEmailForBucket emits base64url-no-pad only', () => {
    const hash = hashEmailForBucket('user@example.com', secret);
    expect(/^[\w\-]+$/iv.test(hash)).toBe(true);
    expect(hash.includes('=')).toBe(false);
    expect(hash.includes('+')).toBe(false);
    expect(hash.includes('/')).toBe(false);
  });
});

describe('rate-limit: acquireEmailRateLimit happy path', () => {
  let bucketKey: string;

  beforeEach(async () => {
    bucketKey = freshBucketKey();
    await deleteBucket(bucketKey);
  });

  test('first acquire inserts count=1 and reports allowed', async () => {
    const now = new Date('2026-04-17T21:00:00Z');
    const outcome = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(now),
    });
    expect(outcome.requestCount).toBe(1);
    expect(outcome.allowed).toBe(true);
    expect(outcome.windowStartedAt.toISOString()).toBe(now.toISOString());
  });

  test('subsequent acquires within the window increment count', async () => {
    const now = new Date('2026-04-17T21:00:00Z');
    const first = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(now),
    });
    const second = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(new Date(now.getTime() + 1000)),
    });
    const third = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(new Date(now.getTime() + 2000)),
    });
    expect(first.requestCount).toBe(1);
    expect(second.requestCount).toBe(2);
    expect(third.requestCount).toBe(3);
    // Window anchor preserved across increments — a passing request
    // must NOT slide the window forward; that would make the limit
    // trivially bypassed by paced calls.
    expect(second.windowStartedAt.toISOString()).toBe(first.windowStartedAt.toISOString());
    expect(third.windowStartedAt.toISOString()).toBe(first.windowStartedAt.toISOString());
  });

  test('reaching max keeps allowed=true; exceeding max sets allowed=false', async () => {
    const now = new Date('2026-04-17T21:00:00Z');
    const clock = fixedClock(now);
    const results = [];
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX + 2; index += 1) {
      // eslint-disable-next-line no-await-in-loop
      const outcome = await acquireEmailRateLimit({ emailHash: bucketKey, nowDate: clock });
      results.push(outcome);
    }
    for (let index = 0; index < EMAIL_RATE_LIMIT_MAX; index += 1) {
      const entry = results[index];
      if (entry === undefined) {
        throw new Error('expected a result within budget');
      }
      expect(entry.allowed).toBe(true);
      expect(entry.requestCount).toBe(index + 1);
    }
    const firstOver = results[EMAIL_RATE_LIMIT_MAX];
    if (firstOver === undefined) {
      throw new Error('expected a first-over-budget result');
    }
    expect(firstOver.allowed).toBe(false);
    expect(firstOver.requestCount).toBe(EMAIL_RATE_LIMIT_MAX + 1);
  });

  test('window expiry resets count to 1 on the next acquire', async () => {
    const tStart = new Date('2026-04-17T21:00:00Z');
    const first = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(tStart),
    });
    expect(first.requestCount).toBe(1);

    // Jump past the window boundary. `windowStartedAt <= now -
    // windowSeconds` is the reset predicate; crossing it by any
    // amount triggers the atomic replace.
    const tReset = new Date(tStart.getTime() + (EMAIL_RATE_LIMIT_WINDOW_SECONDS + 1) * 1000);
    const afterReset = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(tReset),
    });
    expect(afterReset.requestCount).toBe(1);
    expect(afterReset.windowStartedAt.toISOString()).toBe(tReset.toISOString());
  });

  test('window boundary is strictly "<= now - windowSeconds" (exactly at boundary resets)', async () => {
    const tStart = new Date('2026-04-17T21:00:00Z');
    await acquireEmailRateLimit({ emailHash: bucketKey, nowDate: fixedClock(tStart) });

    // Exactly on the boundary: window_started_at + windowSeconds === now.
    const tExact = new Date(tStart.getTime() + EMAIL_RATE_LIMIT_WINDOW_SECONDS * 1000);
    const outcome = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(tExact),
    });
    // Reset predicate `<=` includes the boundary — an exact-equal
    // request kicks off a fresh window. If this flipped to `<`, a
    // long-pole caller sitting exactly at windowSeconds could double
    // the effective limit.
    expect(outcome.requestCount).toBe(1);
    expect(outcome.windowStartedAt.toISOString()).toBe(tExact.toISOString());
  });

  test('one second before boundary still inside window — no reset', async () => {
    const tStart = new Date('2026-04-17T21:00:00Z');
    await acquireEmailRateLimit({ emailHash: bucketKey, nowDate: fixedClock(tStart) });

    const tJustBefore = new Date(tStart.getTime() + (EMAIL_RATE_LIMIT_WINDOW_SECONDS - 1) * 1000);
    const outcome = await acquireEmailRateLimit({
      emailHash: bucketKey,
      nowDate: fixedClock(tJustBefore),
    });
    expect(outcome.requestCount).toBe(2);
    expect(outcome.windowStartedAt.toISOString()).toBe(tStart.toISOString());
  });
});

describe('rate-limit: acquireEmailRateLimit isolation', () => {
  test('independent bucket keys do not interfere', async () => {
    const keyA = freshBucketKey();
    const keyB = freshBucketKey();
    await deleteBucket(keyA);
    await deleteBucket(keyB);
    const now = new Date('2026-04-17T21:00:00Z');
    const clock = fixedClock(now);

    const a1 = await acquireEmailRateLimit({ emailHash: keyA, nowDate: clock });
    const b1 = await acquireEmailRateLimit({ emailHash: keyB, nowDate: clock });
    const a2 = await acquireEmailRateLimit({ emailHash: keyA, nowDate: clock });
    expect(a1.requestCount).toBe(1);
    expect(b1.requestCount).toBe(1);
    expect(a2.requestCount).toBe(2);
  });

  test('concurrent acquires on one key land a consistent final count', async () => {
    const key = freshBucketKey();
    await deleteBucket(key);
    const now = new Date('2026-04-17T21:00:00Z');
    const clock = fixedClock(now);
    const concurrency = 5;

    // Fire N acquires in parallel. The unique constraint on
    // `email_hash` serializes the conflict branch: each acquire reads
    // its own RETURNING row against a consistent post-update state,
    // so the final count must equal N regardless of interleaving.
    const outcomes = await Promise.all(
      Array.from(
        { length: concurrency },
        async () => await acquireEmailRateLimit({ emailHash: key, nowDate: clock }),
      ),
    );

    const counts = outcomes.map((outcome) => outcome.requestCount).toSorted((a, b) => a - b);
    expect(counts).toEqual([1, 2, 3, 4, 5]);

    const finalRows = await db
      .select({ requestCount: emailRateLimit.requestCount })
      .from(emailRateLimit)
      .where(eq(emailRateLimit.emailHash, key));
    expect(finalRows[0]?.requestCount).toBe(concurrency);
  });
});

describe('rate-limit: acquireEmailRateLimit options', () => {
  test('custom max narrows the allowed window', async () => {
    const key = freshBucketKey();
    await deleteBucket(key);
    const now = new Date('2026-04-17T21:00:00Z');
    const clock = fixedClock(now);

    const first = await acquireEmailRateLimit({ emailHash: key, nowDate: clock, max: 1 });
    const second = await acquireEmailRateLimit({ emailHash: key, nowDate: clock, max: 1 });
    expect(first.allowed).toBe(true);
    expect(second.allowed).toBe(false);
    expect(second.requestCount).toBe(2);
  });

  test('custom windowSeconds narrows the reset predicate', async () => {
    const key = freshBucketKey();
    await deleteBucket(key);
    const tStart = new Date('2026-04-17T21:00:00Z');
    const outcome1 = await acquireEmailRateLimit({
      emailHash: key,
      nowDate: fixedClock(tStart),
      windowSeconds: 5,
    });
    expect(outcome1.requestCount).toBe(1);

    // Inside the custom 5s window.
    const outcome2 = await acquireEmailRateLimit({
      emailHash: key,
      nowDate: fixedClock(new Date(tStart.getTime() + 2000)),
      windowSeconds: 5,
    });
    expect(outcome2.requestCount).toBe(2);

    // Outside the custom 5s window — resets.
    const outcome3 = await acquireEmailRateLimit({
      emailHash: key,
      nowDate: fixedClock(new Date(tStart.getTime() + 6000)),
      windowSeconds: 5,
    });
    expect(outcome3.requestCount).toBe(1);
  });
});
