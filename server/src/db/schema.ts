import { relations } from 'drizzle-orm';
import { pgTable, text, timestamp, boolean, index } from 'drizzle-orm/pg-core';

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
 * Device-attestation binding captured at `POST /sign-in/magic-link` time. Step
 * 6 of Part 9 uses this table to enforce `ver:` binding:
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
 * Device-attestation binding captured at sign-in. Step 7 of Part 9 uses this
 * table to bind every authenticated API call to the Secure Enclave key the
 * session was minted under:
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

export const userRelations = relations(user, ({ many }) => ({
  sessions: many(session),
  accounts: many(account),
}));

export const sessionRelations = relations(session, ({ one }) => ({
  user: one(user, {
    fields: [session.userId],
    references: [user.id],
  }),
  attestation: one(sessionAttestation, {
    fields: [session.id],
    references: [sessionAttestation.sessionId],
  }),
}));

export const sessionAttestationRelations = relations(sessionAttestation, ({ one }) => ({
  session: one(session, {
    fields: [sessionAttestation.sessionId],
    references: [session.id],
  }),
}));

export const accountRelations = relations(account, ({ one }) => ({
  user: one(user, {
    fields: [account.userId],
    references: [user.id],
  }),
}));
