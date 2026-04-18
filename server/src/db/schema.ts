import { relations } from 'drizzle-orm';
import {
  pgTable,
  text,
  timestamp,
  boolean,
  index,
  integer,
  unique,
  bigint,
} from 'drizzle-orm/pg-core';

export const user = pgTable('user', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  emailVerified: boolean('email_verified').default(false).notNull(),
  image: text('image'),
  createdAt: timestamp('created_at').notNull(),
  updatedAt: timestamp('updated_at')
    .$onUpdate(() => new Date())
    .notNull(),
});

export const session = pgTable(
  'session',
  {
    id: text('id').primaryKey(),
    expiresAt: timestamp('expires_at').notNull(),
    token: text('token').notNull().unique(),
    createdAt: timestamp('created_at').notNull(),
    updatedAt: timestamp('updated_at')
      .$onUpdate(() => new Date())
      .notNull(),
    ipAddress: text('ip_address'),
    userAgent: text('user_agent'),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
  },
  (table) => [index('session_userId_idx').on(table.userId)],
);

export const account = pgTable(
  'account',
  {
    id: text('id').primaryKey(),
    accountId: text('account_id').notNull(),
    providerId: text('provider_id').notNull(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    accessToken: text('access_token'),
    refreshToken: text('refresh_token'),
    idToken: text('id_token'),
    accessTokenExpiresAt: timestamp('access_token_expires_at'),
    refreshTokenExpiresAt: timestamp('refresh_token_expires_at'),
    scope: text('scope'),
    password: text('password'),
    createdAt: timestamp('created_at').notNull(),
    updatedAt: timestamp('updated_at')
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index('account_userId_idx').on(table.userId)],
);

export const verification = pgTable(
  'verification',
  {
    id: text('id').primaryKey(),
    identifier: text('identifier').notNull(),
    value: text('value').notNull(),
    expiresAt: timestamp('expires_at').notNull(),
    createdAt: timestamp('created_at').notNull(),
    updatedAt: timestamp('updated_at')
      .$onUpdate(() => new Date())
      .notNull(),
  },
  (table) => [index('verification_identifier_idx').on(table.identifier)],
);

/**
 * Device-attestation binding captured at `POST /sign-in/magic-link` time. Used
 * by the attestation plugin to enforce the `ver:` binding:
 *
 * - On `/sign-in/magic-link`, the magic-link plugin's `sendMagicLink` callback
 *   writes `(token_identifier, fingerprint_hash, public_key_spki, expires_at)`
 *   here. The `token_identifier` is `base64url-no-pad(sha256(magic_link_token))`
 *   — byte-for-byte what better-auth stores in `verification.identifier` for
 *   the same token (see `magicLink({ storeToken: 'hashed' })`). Storing a
 *   digest (not the plaintext token) means a DB read cannot be redeemed into
 *   a sign-in, consistent with the invariant that the magic-link token never
 *   hits durable storage in plaintext.
 * - On `GET /magic-link/verify`, the attestation plugin derives the same
 *   identifier from the `ver:<token>` binding and looks this row up. The
 *   stored `fingerprint_hash` and `public_key_spki` are compared byte-for-byte
 *   against the verify-time attestation; a mismatch rejects with
 *   `DEVICE_MISMATCH` before the magic-link plugin ever consumes its
 *   verification row.
 *
 * `expires_at` tracks the magic-link token's expiry so stale rows are
 * self-evident; housekeeping cleanup is orthogonal (rows age out naturally
 * within the 5-minute token lifetime).
 *
 * Values are base64 strings rather than `bytea`: the PostgreSQL driver on
 * `bun-sql` does not round-trip `bytea` without adapter glue, and the rows are
 * small fixed-size payloads (32-byte fingerprint hash + 91-byte SPKI). Text
 * encoding keeps the schema portable and the byte-equal comparison is
 * string-level (see `magic-link-attestation.ts`).
 */
export const magicLinkAttestation = pgTable(
  'magic_link_attestation',
  {
    id: text('id').primaryKey(),
    tokenIdentifier: text('token_identifier').notNull().unique(),
    fingerprintHash: text('fingerprint_hash').notNull(),
    publicKeySpki: text('public_key_spki').notNull(),
    expiresAt: timestamp('expires_at').notNull(),
    createdAt: timestamp('created_at').notNull(),
  },
  (table) => [index('magic_link_attestation_expires_at_idx').on(table.expiresAt)],
);

/**
 * Device-attestation binding captured at sign-in. Binds every authenticated
 * API call to the Secure Enclave key the session was minted under:
 *
 * - On `/magic-link/verify` and `/sign-in/social`, the attestation plugin's
 *   after-hook writes `(session_id, fingerprint_hash, public_key_spki)` here
 *   once better-auth has created the session row. The incoming
 *   `x-device-attestation` header has already been fully validated by the
 *   before-hook (structural parse, SPKI, binding tag, ECDSA, nonce or
 *   stored-(fph, pk) match, ±60s skew) before this row is written, so the pk
 *   captured here is exactly what the sign-in ceremony accepted.
 * - On every protected-route call, the middleware parses the request's
 *   `api:` attestation, looks up this row by the resolved session's `id`,
 *   verifies the ECDSA signature against the stored SPKI (NOT the wire
 *   SPKI), and enforces the ±60s skew window. Verifying under the stored
 *   key is the load-bearing defence: a captured bearer paired with a fresh
 *   attestation signed by any other key cannot satisfy the verify.
 *
 * 1:1 with `session` via the unique `session_id` FK. `ON DELETE CASCADE`
 * keeps the binding's lifetime equal to the session's: sign-out, session
 * revoke, or user delete drops this row automatically. A missing row on a
 * protected call surfaces as `SESSION_ATTESTATION_MISSING` — this should
 * never happen in practice (sign-in writes it atomically inside the sign-in
 * request) but the middleware rejects with 401 rather than treating the
 * absence as "skip the gate".
 *
 * Values are base64 strings rather than `bytea`: the PostgreSQL driver on
 * `bun-sql` does not round-trip `bytea` without adapter glue, and the rows
 * are small fixed-size payloads (32-byte fingerprint hash + 91-byte SPKI).
 * Text encoding keeps the schema portable and the byte-equal comparison is
 * string-level (see `session-attestation.ts`).
 */
export const sessionAttestation = pgTable(
  'session_attestation',
  {
    id: text('id').primaryKey(),
    sessionId: text('session_id')
      .notNull()
      .unique()
      .references(() => session.id, { onDelete: 'cascade' }),
    fingerprintHash: text('fingerprint_hash').notNull(),
    publicKeySpki: text('public_key_spki').notNull(),
    createdAt: timestamp('created_at').notNull(),
  },
  (table) => [index('session_attestation_session_id_idx').on(table.sessionId)],
);

/**
 * Idempotency ledger — the write-replay defence that closes the 60s residual
 * window left open by per-request attestation.
 *
 * The protected-route middleware pins every authenticated API call to the
 * per-session Secure-Enclave key, so a captured bearer alone is inert. But a captured
 * `(bearer, fresh api: attestation)` pair is briefly replayable within the
 * ±60s attestation skew window. Read replays inside that window are
 * harmless — they surface state the attacker already observed — but a write
 * replay could re-execute a mutation the user didn't authorise a second
 * time. This table dedupes those replays on `(session_id, idempotency_key)`:
 *
 * - The mutating-route middleware (`idempotency.ts`) acquires a pending
 *   lease on the first request under a given `(session, key)`, runs the
 *   handler, and captures the completed response (status, body,
 *   content-type). A subsequent request with the same `(session, key)` and
 *   an identical `request_hash` returns the cached response without
 *   re-executing the handler.
 * - `request_hash` is SHA-256 over `METHOD || '\n' || path || '\n' || body`,
 *   base64url-no-pad encoded. A replay with the same key but a different
 *   method / path / body is rejected as `IDEMPOTENCY_KEY_MISMATCH` — this
 *   is how a client bug surfaces instead of accidentally overwriting a
 *   prior mutation's cache entry.
 * - Pending leases (`response_body IS NULL`) that another caller observes
 *   produce `IDEMPOTENCY_REQUEST_IN_PROGRESS`, so a concurrent duplicate
 *   cannot double-execute while the original is still running.
 * - `expires_at` is set to `now + IDEMPOTENCY_TTL_SECONDS` (10 minutes).
 *   The TTL is deliberately an order of magnitude larger than the 60s skew
 *   window so legitimate client retries over flaky networks still hit the
 *   cache, while expired rows are replaced atomically by the acquire path's
 *   `ON CONFLICT DO UPDATE … WHERE expires_at <= now` predicate.
 *
 * `ON DELETE CASCADE` on `session_id` keeps the row lifetime bounded by the
 * owning session: sign-out, session revoke, or user delete drop every
 * idempotency record atomically. A session that no longer exists cannot
 * authenticate a fresh mutating request in the first place, so the residual
 * rows would be dead weight.
 *
 * Response body is persisted as text because every mutating route on this
 * server returns JSON (see `successResponse`/`errorResponse` in
 * `lib/http.ts`); storing bytes would require driver glue that `bun-sql`
 * does not round-trip cleanly, and the idempotency gate rebuilds the
 * response with `Content-Type` intact from `response_content_type` so the
 * wire contract the client observes on a replay is byte-identical.
 */
export const idempotencyRecord = pgTable(
  'idempotency_record',
  {
    id: text('id').primaryKey(),
    sessionId: text('session_id')
      .notNull()
      .references(() => session.id, { onDelete: 'cascade' }),
    idempotencyKey: text('idempotency_key').notNull(),
    requestHash: text('request_hash').notNull(),
    statusCode: integer('status_code'),
    responseBody: text('response_body'),
    responseContentType: text('response_content_type'),
    createdAt: timestamp('created_at').notNull(),
    expiresAt: timestamp('expires_at').notNull(),
  },
  (table) => [
    index('idempotency_record_session_id_idx').on(table.sessionId),
    index('idempotency_record_expires_at_idx').on(table.expiresAt),
    unique('idempotency_record_session_key_unique').on(table.sessionId, table.idempotencyKey),
  ],
);

/**
 * Per-email cooldown ledger — the enumeration-resistant half of the
 * sign-in rate-limit posture.
 *
 * Every `POST /sign-in/magic-link` request runs the email through a
 * cooldown check before `sendMagicLink` fires. The row stores a sliding
 * window:
 *
 * - `email_hash` is `HMAC-SHA256(normalize(email), BETTER_AUTH_SECRET)`
 *   base64url-no-pad. The raw email never lands here — a DB read reveals
 *   only which opaque buckets were hot, not which addresses. The secret
 *   extends across restart because it's pinned to `BETTER_AUTH_SECRET`,
 *   which the server already requires be stable across deploys.
 * - `window_started_at` anchors the active window. `request_count` is
 *   the number of requests that have landed in it. On each acquire, if
 *   `now - window_started_at >= EMAIL_RATE_LIMIT_WINDOW_SECONDS` the
 *   acquire path atomically resets both fields; otherwise it increments
 *   the count.
 * - A caller whose post-acquire `request_count` exceeds
 *   `EMAIL_RATE_LIMIT_MAX` is over-budget. The magic-link before-hook
 *   short-circuits with the same 200 `{ status: true }` body the plugin
 *   emits on success — byte-identical to a fresh-email acceptance so an
 *   attacker cannot distinguish a cooldown from a real send.
 *
 * Single unique key on `email_hash`. `ON CONFLICT (email_hash) DO
 * UPDATE ... RETURNING` collapses the "insert new / increment existing /
 * reset expired" cases into one round-trip that is race-safe under
 * concurrent POSTs. `updated_at` tracks the most recent activity so a
 * cleanup pass (future) can GC buckets that have been cold for longer
 * than the window.
 *
 * This table is orthogonal to the `rate_limit` table better-auth uses
 * for its per-IP / per-path built-in limiter. Both coexist: per-IP
 * rejects distributed floods loudly with a 429; per-email silently
 * swallows repeats to defeat email enumeration.
 */
export const emailRateLimit = pgTable(
  'email_rate_limit',
  {
    id: text('id').primaryKey(),
    emailHash: text('email_hash').notNull().unique(),
    windowStartedAt: timestamp('window_started_at').notNull(),
    requestCount: integer('request_count').notNull(),
    updatedAt: timestamp('updated_at').notNull(),
  },
  (table) => [index('email_rate_limit_window_started_at_idx').on(table.windowStartedAt)],
);

/**
 * Better-auth's built-in rate-limit storage (per-(IP, path) counters).
 *
 * Persisted to Postgres instead of in-memory so a restart does not
 * reset counters and so multiple server replicas share one ledger —
 * required once the coordination server runs behind Cloudflare Tunnel
 * with any horizontal-scale expansion. Schema matches exactly what
 * `@better-auth/core`'s `getAuthTables` emits for `rateLimit` when
 * `rateLimit.storage === 'database'`:
 *
 * - `key`: `<ip>:<normalized-path>` (compound per request dimension).
 * - `count`: number of requests in the current window.
 * - `last_request`: epoch-millis of the most recent request; better-auth
 *   computes window expiry relative to `Date.now()`.
 *
 * The property names `key`, `count`, `lastRequest` match better-auth's
 * default field names so no `rateLimit.fields` override is needed on
 * the factory; column names are snake_case for schema consistency
 * with the rest of this file.
 */
export const rateLimit = pgTable('rate_limit', {
  id: text('id').primaryKey(),
  key: text('key').notNull().unique(),
  count: integer('count').notNull(),
  lastRequest: bigint('last_request', { mode: 'number' }).notNull(),
});

export const userRelations = relations(user, ({ many }) => ({
  sessions: many(session),
  accounts: many(account),
}));

export const sessionRelations = relations(session, ({ one, many }) => ({
  user: one(user, {
    fields: [session.userId],
    references: [user.id],
  }),
  attestation: one(sessionAttestation, {
    fields: [session.id],
    references: [sessionAttestation.sessionId],
  }),
  idempotencyRecords: many(idempotencyRecord),
}));

export const sessionAttestationRelations = relations(sessionAttestation, ({ one }) => ({
  session: one(session, {
    fields: [sessionAttestation.sessionId],
    references: [session.id],
  }),
}));

export const idempotencyRecordRelations = relations(idempotencyRecord, ({ one }) => ({
  session: one(session, {
    fields: [idempotencyRecord.sessionId],
    references: [session.id],
  }),
}));

export const accountRelations = relations(account, ({ one }) => ({
  user: one(user, {
    fields: [account.userId],
    references: [user.id],
  }),
}));
