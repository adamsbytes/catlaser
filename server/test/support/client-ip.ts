import { randomBytes } from 'node:crypto';

/**
 * Per-call IP generator for integration tests.
 *
 * The coordination server enables better-auth's built-in per-(IP,
 * path) rate limiter with a tight `max: 10 / window: 60` on sign-in
 * paths (see `~/lib/auth.ts`). Without isolation, tests in this repo
 * would either share `127.0.0.1` (default in dev/test when no IP
 * header is present) or share whatever stable IP a suite picked up-
 * front, both of which collapse onto one rate-limit bucket and blow
 * past the cap once a single file runs more than ~10 sign-in calls.
 *
 * Every test request attaches a fresh `X-Forwarded-For` — which
 * `advanced.ipAddress.ipAddressHeaders` is configured to read — so
 * the limiter sees a different client for every call and never
 * trips. The dedicated rate-limit suite in `test/rate-limit*.test.ts`
 * pins a stable IP via `uniqueClientIp()` called once per describe
 * block, then passes the same string to every request in that
 * block, so it CAN exercise the limiter.
 *
 * Uses `crypto.randomBytes` (allowed under the repo's no-Math.random
 * lint rule) to produce RFC 1918 `10.0.0.0/8` addresses — a private
 * range that is never routed on the public internet, so the addresses
 * cannot collide with any real traffic a live server has seen. The
 * 16M-address space is wide enough that a full test run cannot
 * exhaust it, which is critical: better-auth's rate-limit storage
 * persists across test files inside one `bun test` invocation, and a
 * collision between two files (each thinking "its" IP is fresh)
 * would cross-contaminate state.
 */

const RFC_1918_PRIVATE_PREFIX = '10.';

/**
 * Fresh IPv4 in the RFC 1918 `10.0.0.0/8` range. Every call returns a
 * different value; tests composed of many HTTP calls burn through
 * these without holding state. The 24-bit payload (3 random bytes
 * → ~16M distinct values) makes collisions across the full test
 * suite negligible.
 */
export const uniqueClientIp = (): string => {
  const [a, b, c] = randomBytes(3);
  if (a === undefined || b === undefined || c === undefined) {
    throw new Error('randomBytes(3) returned a truncated buffer');
  }
  return `${RFC_1918_PRIVATE_PREFIX}${a.toString()}.${b.toString()}.${c.toString()}`;
};

/**
 * `{ 'X-Forwarded-For': '198.51.100.42' }`-shaped header map for
 * spread into any test's request-header object. Shorthand for the
 * call-site one-liner `{ ...uniqueClientIpHeader(), ...rest }`.
 */
export const uniqueClientIpHeader = (): Readonly<Record<string, string>> => ({
  'X-Forwarded-For': uniqueClientIp(),
});
