import { createHmac, randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import type { BetterAuthPlugin } from 'better-auth/types';
import { createAuthMiddleware } from 'better-auth/api';
import { emailRateLimit } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Per-email cooldown on `POST /sign-in/magic-link`.
 *
 * The coordination server already carries a per-(IP, path) rate limit
 * courtesy of better-auth's built-in `rateLimit` layer — that defeats
 * a distributed flood from a single source with a loud 429. It does NOT
 * defeat the other half of the enumeration model: an attacker who spans
 * IPs and tries to hammer a specific victim's inbox to mailbomb them
 * into clicking a confused link, or (less dramatically) to probe whether
 * the server is actively issuing magic links for a given address. A
 * distinguishable 429 from the per-IP limiter leaks nothing about the
 * email, but any per-email signal that *differs* from the success path
 * — a 429, a distinct body shape, an extra header, a different timing —
 * would be an enumeration oracle.
 *
 * This module closes that oracle. Every magic-link sign-in request runs
 * through `acquireEmailRateLimit` before `sendMagicLink` is allowed to
 * fire. Over-budget requests are swallowed silently: the before-hook
 * short-circuits with `ctx.json({ status: true })` — the exact body
 * better-auth's magic-link plugin produces on a successful send — and
 * no email is emitted. A legitimate email re-request after the cooldown
 * passes through untouched. An attacker hammering the endpoint with a
 * single victim's address sees byte-identical 200 responses whether the
 * limiter swallowed the request or a real email went out, so the rate
 * limit carries no enumeration signal.
 *
 * The per-email bucket is keyed on `HMAC-SHA256(normalize(email),
 * BETTER_AUTH_SECRET)` encoded base64url-no-pad. Hashing with the server
 * secret means a DB read (backup leak, read replica) reveals only which
 * opaque buckets were hot, not which addresses — same PII minimization
 * posture the magic-link verification table already takes on its tokens.
 * Normalization is `trim().toLowerCase()`: two inbound submissions that
 * would hit the same mailbox 99% of the time must collide in the bucket
 * space, otherwise the rate limit is trivially bypassed by case-flipping.
 *
 * Atomic acquisition is a single `INSERT … ON CONFLICT (email_hash) DO
 * UPDATE … RETURNING`. CASE expressions inside `DO UPDATE` pick between
 * "window has expired, reset to a fresh one" and "window still active,
 * increment". A concurrent pair of POSTs for the same email race on the
 * unique constraint: the loser enters the conflict branch and observes
 * the winner's row — both are safe, both get a real count. The returned
 * `request_count` is the total for the active window; anything strictly
 * greater than `EMAIL_RATE_LIMIT_MAX` is over-budget.
 *
 * Ordering relative to other gates: the attestation plugin's before-hook
 * runs before this one (plugin registration order in `auth.ts`), so an
 * invalid attestation 401s before a DB row is touched. A captured-but-
 * valid attestation still hits this gate — which is the point: captured
 * sessions are exactly the scenario where an attacker can forge the wire
 * attestation but cannot out-spam the per-email cooldown.
 */

/**
 * Window length, in seconds, over which `EMAIL_RATE_LIMIT_MAX` applies.
 * Five minutes is long enough that a user who's asked for a magic link
 * and lost it in their inbox still has headroom for a retry, and short
 * enough that a real user retrying after an SMTP delay still passes
 * within one natural session.
 */
export const EMAIL_RATE_LIMIT_WINDOW_SECONDS = 300;

/**
 * Hard cap on magic-link sign-in requests per email per window. A human
 * typing the wrong email, retrying, correcting, and retrying again can
 * hit 3 comfortably; an automated spammer targeting one inbox cannot
 * ramp past it without waiting out the window.
 */
export const EMAIL_RATE_LIMIT_MAX = 3;

/**
 * Normalize an email address for bucket keying. Trim surrounding
 * whitespace, lowercase everything. We deliberately do NOT strip
 * plus-addressing or dot-variants: treating `foo+1@x.com` and
 * `foo@x.com` as the same bucket would be wrong for users of email
 * systems that route sub-addressing independently, and the attacker
 * value of doing so is small anyway (both variants still send the
 * user email, which the per-IP limiter catches at scale).
 */
export const normalizeEmailForBucket = (email: string): string => email.trim().toLowerCase();

/**
 * Derive the opaque bucket key stored in `email_rate_limit.email_hash`.
 * HMAC-SHA256 over the normalized email with the server secret. Output
 * is base64url-no-pad for DB portability and URL-safe logging.
 *
 * The secret must be stable across deploys for the key to remain
 * meaningful across restart — `BETTER_AUTH_SECRET` is already required
 * to be stable for session/cookie signing, so tying rate-limit keys
 * to the same secret introduces no fresh rotation constraint.
 */
export const hashEmailForBucket = (email: string, secret: string): string =>
  createHmac('sha256', secret)
    .update(normalizeEmailForBucket(email), 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/**
 * Test-only seam for the acquire path's clock. Production omits it and
 * reads the real wall clock; tests inject a frozen `Date` so window-
 * reset behaviour is deterministic under concurrent acquires.
 */
export type NowDateFn = () => Date;
const defaultNowDate: NowDateFn = () => new Date();

export interface AcquireOutcome {
  /** Total requests in the active window after this acquire landed. */
  readonly requestCount: number;
  /** Start timestamp of the active window (reset on expiry). */
  readonly windowStartedAt: Date;
  /** `true` iff `requestCount <= EMAIL_RATE_LIMIT_MAX`. */
  readonly allowed: boolean;
}

export interface AcquireEmailRateLimitOptions {
  readonly emailHash: string;
  readonly nowDate?: NowDateFn;
  readonly windowSeconds?: number;
  readonly max?: number;
}

/**
 * Atomically claim a slot in the per-email bucket. Returns the
 * post-acquire row state. Callers decide how to respond to
 * `allowed = false` — the magic-link plugin swallows silently for
 * enumeration resistance, but the function itself is neutral about
 * the policy.
 *
 * Implementation: single `INSERT … ON CONFLICT DO UPDATE … RETURNING`.
 * The DO UPDATE branch uses CASE expressions to either (a) reset the
 * window when `window_started_at <= now - windowSeconds`, or (b)
 * increment the count when the window is still active. There is no
 * WHERE clause on DO UPDATE — the update always applies — so the
 * RETURNING clause is guaranteed to produce exactly one row.
 *
 * `randomUUID()` feeds the `id` column on the INSERT path; it is
 * ignored on the UPDATE path (the existing row's id is preserved).
 */
export const acquireEmailRateLimit = async (
  options: AcquireEmailRateLimitOptions,
): Promise<AcquireOutcome> => {
  const nowDate = (options.nowDate ?? defaultNowDate)();
  const windowSeconds = options.windowSeconds ?? EMAIL_RATE_LIMIT_WINDOW_SECONDS;
  const max = options.max ?? EMAIL_RATE_LIMIT_MAX;
  const windowBoundary = new Date(nowDate.getTime() - windowSeconds * 1000);

  const rows = await db
    .insert(emailRateLimit)
    .values({
      id: randomUUID(),
      emailHash: options.emailHash,
      windowStartedAt: nowDate,
      requestCount: 1,
      updatedAt: nowDate,
    })
    .onConflictDoUpdate({
      target: emailRateLimit.emailHash,
      set: {
        windowStartedAt: sql`CASE WHEN ${emailRateLimit.windowStartedAt} <= ${windowBoundary} THEN ${nowDate}::timestamp ELSE ${emailRateLimit.windowStartedAt} END`,
        requestCount: sql`CASE WHEN ${emailRateLimit.windowStartedAt} <= ${windowBoundary} THEN 1 ELSE ${emailRateLimit.requestCount} + 1 END`,
        updatedAt: nowDate,
      },
    })
    .returning({
      requestCount: emailRateLimit.requestCount,
      windowStartedAt: emailRateLimit.windowStartedAt,
    });

  const row = rows[0];
  if (row === undefined) {
    // Would only fire if the PG driver dropped RETURNING output, which
    // is not a race mode — either DO UPDATE ran and there is a row, or
    // the INSERT ran and there is a row. Surfacing as a loud error
    // rather than a silent "allowed" keeps the invariant auditable.
    throw new Error(
      'acquireEmailRateLimit: INSERT ... ON CONFLICT DO UPDATE RETURNING produced no row',
    );
  }

  const windowStartedAt = row.windowStartedAt instanceof Date ? row.windowStartedAt : nowDate;
  return {
    requestCount: row.requestCount,
    windowStartedAt,
    allowed: row.requestCount <= max,
  };
};

/**
 * Path gated by the per-email cooldown. Only one endpoint today; the
 * single-path `Set` keeps a future addition (social sign-in, say,
 * once we expose it to an email-keyed cooldown) discoverable at one
 * call site.
 */
const GATED_PATHS: ReadonlySet<string> = new Set(['/sign-in/magic-link']);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/**
 * Pull `body.email` if it's a non-empty string. Returns `undefined`
 * when absent, malformed, or typed as anything other than a string —
 * we hand over to better-auth's body schema to reject those cases
 * with its own 400. Silently skipping the rate limit for malformed
 * bodies is correct: they never reach `sendMagicLink` anyway.
 */
const extractBodyEmail = (body: unknown): string | undefined => {
  if (!isRecord(body)) {
    return undefined;
  }
  const { email } = body;
  if (typeof email !== 'string' || email.trim().length === 0) {
    return undefined;
  }
  return email;
};

export interface RateLimitPluginOptions {
  /**
   * Server-side secret used to derive the `email_hash` bucket key.
   * Must be stable across restarts. Production wires
   * `env.BETTER_AUTH_SECRET`; tests inject a fixed string.
   */
  readonly secret: string;
  /**
   * Test-only clock injection. Mirrors `attestationNowSeconds` in the
   * attestation plugin — lets suites drive window-reset behaviour
   * deterministically. Production omits.
   */
  readonly nowDate?: NowDateFn;
  /**
   * Window length override. Production omits; callers tuning limits
   * for specific environments (e.g. canary deployments) pass a value.
   */
  readonly windowSeconds?: number;
  /**
   * Max override. Same rationale as `windowSeconds`.
   */
  readonly max?: number;
}

/**
 * Shape of the better-auth magic-link plugin's 200 response body.
 * Reproducing it here as a const keeps the enumeration-resistant
 * short-circuit byte-identical to the real success — if that plugin
 * ever changes its body, a refresh of this constant is the one-line
 * fix to keep the invariant intact.
 */
const IDENTICAL_SUCCESS_BODY = { status: true } as const;

/**
 * Build the per-email rate-limit plugin. Registered AFTER the
 * attestation plugin in `auth.ts` so a bad attestation 401s before
 * the rate-limit ledger is touched.
 *
 * The plugin's sole concern is the before-hook. It:
 *
 * 1. Matches only `/sign-in/magic-link` (the `matcher` callback).
 * 2. Extracts `body.email`. If malformed, skips the gate and lets
 *    better-auth's body validator reject the request on its own.
 * 3. Derives the `email_hash` via HMAC and atomically acquires a
 *    slot.
 * 4. If `allowed`, returns nothing — the request proceeds to the
 *    magic-link endpoint.
 * 5. If over-budget, short-circuits with `ctx.json({ status: true })`.
 *    `sendMagicLink` is never invoked. The caller sees a 200 body that
 *    is byte-identical to a legitimate send, which is the entire
 *    enumeration-resistance contract.
 */
export const buildEmailRateLimitPlugin = (options: RateLimitPluginOptions): BetterAuthPlugin => {
  const { secret } = options;
  const nowDate = options.nowDate ?? defaultNowDate;
  const windowSeconds = options.windowSeconds ?? EMAIL_RATE_LIMIT_WINDOW_SECONDS;
  const max = options.max ?? EMAIL_RATE_LIMIT_MAX;

  return {
    id: 'email-rate-limit',
    hooks: {
      before: [
        {
          matcher: (context) => {
            const { path } = context;
            return typeof path === 'string' && GATED_PATHS.has(path);
          },
          handler: createAuthMiddleware(async (ctx) => {
            const body: unknown = ctx.body;
            const email = extractBodyEmail(body);
            // Skip the gate on a missing or malformed email —
            // better-auth's body validator will 400 on its own and
            // `sendMagicLink` never fires on a rejected body. The
            // `{ context: {} }` return is better-auth's "merge empty
            // context and continue to the next hook" signal, which
            // gets us past the `consistent-return` lint without
            // landing a useless `return undefined`.
            if (email === undefined) {
              return { context: {} };
            }
            const emailHash = hashEmailForBucket(email, secret);
            const outcome = await acquireEmailRateLimit({
              emailHash,
              nowDate,
              windowSeconds,
              max,
            });
            if (outcome.allowed) {
              return { context: {} };
            }
            // Enumeration-resistant swallow: return the magic-link
            // plugin's own success body as a short-circuit. `ctx.json`
            // is typed `Promise<R>` in better-call even though the
            // runtime returns synchronously — a bare `return ctx.json`
            // trips `@typescript-eslint/return-await`, so we await the
            // (already-resolved) value to satisfy the rule. The
            // returned JSONResponse is what better-auth's hook runner
            // lifts into the HTTP response, bypassing the endpoint
            // handler entirely.
            return await ctx.json({ ...IDENTICAL_SUCCESS_BODY });
          }),
        },
      ],
    },
  };
};
