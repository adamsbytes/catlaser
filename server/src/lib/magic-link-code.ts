import { createHmac, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { and, eq, gt, lt, sql } from 'drizzle-orm';
import { magicLinkCode } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Backup-code path for magic-link sign-in.
 *
 * Every `POST /sign-in/magic-link` issues a 6-digit numeric code alongside
 * the URL token. The code is emailed beneath the tap link and is redeemed
 * via `POST /magic-link/verify-by-code`; redeeming either path invalidates
 * the other because the two rows carry the same `token_identifier`.
 *
 * This module owns three invariants:
 *
 * 1. The code is generated via a rejection-sampling call into `randomInt`
 *    so the distribution is uniform over `000000..999999` — no modulo bias.
 * 2. The stored lookup key is an HMAC of the code under `BETTER_AUTH_SECRET`
 *    rather than a plain digest. A DB leak therefore yields an opaque
 *    identifier that cannot be linearly searched across the 1M code space
 *    without the server secret, matching the per-email `email_rate_limit`
 *    posture.
 * 3. Every byte-match failure decrements `attempts_remaining` in the same
 *    UPDATE. At zero the row is deleted. Ten attempts x 1M code space is
 *    not exploitable before the per-IP 429 floor engages, and a legitimate
 *    user who mistypes once still has nine chances.
 */

/** Default code lifetime. Mirrors `MAGIC_LINK_EXPIRES_IN_SECONDS`. */
export const MAGIC_LINK_CODE_EXPIRES_IN_SECONDS = 60 * 5;

/**
 * Attempts allowed per code before the row is deleted. Chosen as the
 * smallest value that absorbs two or three typos without punishing a
 * user who is mid-keypad-bounce — below this floor a legitimate user
 * with fat fingers risks a `INVALID_CODE` where a retry would have
 * otherwise succeeded.
 */
export const MAGIC_LINK_CODE_MAX_ATTEMPTS = 10;

/** Digits in the emitted code. Six balances autofill ergonomics against brute-force cost. */
export const MAGIC_LINK_CODE_DIGITS = 6;

const CODE_MODULUS = 10 ** MAGIC_LINK_CODE_DIGITS;

const normalizeCode = (code: string): string => code.replaceAll(/[\s\-]/gv, '');

/**
 * Is this string a well-formed backup code after whitespace / hyphen stripping?
 *
 * The iOS client's `BackupCode` type normalises before sending so the server
 * rarely sees a non-digit payload, but keeping the structural gate here too
 * means a direct API caller can't flood the HMAC path with 1MB strings.
 */
export const isPlausibleBackupCode = (code: string): boolean => {
  const normalized = normalizeCode(code);
  if (normalized.length !== MAGIC_LINK_CODE_DIGITS) {
    return false;
  }
  for (const char of normalized) {
    const codePoint = char.codePointAt(0);
    if (codePoint === undefined || codePoint < 0x30 || codePoint > 0x39) {
      return false;
    }
  }
  return true;
};

/**
 * Generate a uniformly-distributed 6-digit backup code. `randomInt` uses
 * `/dev/urandom` on Linux (via `crypto.randomFillSync`) and rejection-
 * samples internally so the output distribution is exactly uniform over
 * `[0, CODE_MODULUS)` — no modulo bias, no off-by-one. Zero-padded to
 * width so `000042` is legal on the wire.
 */
export const generateBackupCode = (): string =>
  randomInt(0, CODE_MODULUS).toString(10).padStart(MAGIC_LINK_CODE_DIGITS, '0');

/**
 * Derive the DB key for a backup code. HMAC-SHA256 under the server
 * secret, base64url-no-pad. Input is normalised first so a code entered
 * as `"123 456"` or `"123-456"` hashes identically to `"123456"`.
 *
 * A DB read cannot be linearly searched backward into the 1M code space
 * without the secret; the server secret is already required to be stable
 * across restart, so the scheme survives deploys without re-issuing rows.
 */
export const deriveCodeIdentifier = (code: string, secret: string): string => {
  const normalized = normalizeCode(code);
  return createHmac('sha256', secret)
    .update(normalized, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
};

const encodeStandardBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');

const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeStandardBase64(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

const utf8 = new TextEncoder();

/** Byte-equal comparison over UTF-8 encoding, constant-time. */
const timingSafeStringEquals = (a: string, b: string): boolean => {
  const aBytes = utf8.encode(a);
  const bBytes = utf8.encode(b);
  if (aBytes.length !== bBytes.length) {
    return false;
  }
  return timingSafeEqual(aBytes, bBytes);
};

export interface StoreMagicLinkCodeInput {
  readonly code: string;
  readonly secret: string;
  readonly plaintextToken: string;
  readonly tokenIdentifier: string;
  readonly fingerprintHash: Uint8Array;
  readonly publicKeySPKI: Uint8Array;
  readonly expiresAt: Date;
  readonly createdAt?: Date;
}

/**
 * Write the backup-code row captured during `sendMagicLink`. Mirrors
 * `storeMagicLinkAttestation` — an insert failure must propagate so the
 * outgoing email is not sent under a missing row (the user would be stuck
 * with a code the server cannot recognise).
 *
 * `ON CONFLICT DO UPDATE` on the `code_identifier` unique constraint
 * guards against a collision in the 1M code space (birthday odds over
 * 5-minute windows with realistic traffic are negligible but non-zero).
 * Replacing on collision is safer than failing the outer send — the
 * losing code's prior request would have already been serviced and
 * either consumed or expired by the time this path runs. Opportunistic
 * housekeeping drops expired rows after each successful insert so the
 * table stays bounded without a cron.
 */
export const storeMagicLinkCode = async (input: StoreMagicLinkCodeInput): Promise<void> => {
  const createdAt = input.createdAt ?? new Date();
  const codeIdentifier = deriveCodeIdentifier(input.code, input.secret);
  const row = {
    id: randomUUID(),
    codeIdentifier,
    plaintextToken: input.plaintextToken,
    tokenIdentifier: input.tokenIdentifier,
    fingerprintHash: encodeBase64UrlNoPad(input.fingerprintHash),
    publicKeySpki: encodeStandardBase64(input.publicKeySPKI),
    attemptsRemaining: MAGIC_LINK_CODE_MAX_ATTEMPTS,
    expiresAt: input.expiresAt,
    createdAt,
  };
  await db
    .insert(magicLinkCode)
    .values(row)
    .onConflictDoUpdate({
      target: magicLinkCode.codeIdentifier,
      set: {
        plaintextToken: row.plaintextToken,
        tokenIdentifier: row.tokenIdentifier,
        fingerprintHash: row.fingerprintHash,
        publicKeySpki: row.publicKeySpki,
        attemptsRemaining: row.attemptsRemaining,
        expiresAt: row.expiresAt,
        createdAt: row.createdAt,
      },
    });
  await db.delete(magicLinkCode).where(lt(magicLinkCode.expiresAt, createdAt));
};

export type ConsumeCodeOutcome =
  | { readonly kind: 'match'; readonly plaintextToken: string; readonly tokenIdentifier: string }
  | { readonly kind: 'mismatch' }
  | { readonly kind: 'not-found' };

export interface ConsumeMagicLinkCodeInput {
  readonly code: string;
  readonly secret: string;
  readonly wireFingerprintHash: Uint8Array;
  readonly wirePublicKeySPKI: Uint8Array;
}

/**
 * Atomically look up the backup-code row, byte-match the attestation
 * pair, and either delete the row (match) or decrement
 * `attempts_remaining` (miss). Returns one of three outcomes:
 *
 * - `match` — fph AND pk byte-equal the stored values. The row is
 *   deleted in the same transaction; the caller now owns the
 *   `plaintext_token` and `token_identifier` to finalise sign-in via
 *   better-auth's internal adapter.
 * - `mismatch` — row existed (not expired) but at least one of fph /
 *   pk differed. Attempt counter decremented; row deleted if it
 *   reached zero. The caller surfaces this as `DEVICE_MISMATCH` so
 *   the wire shape matches the URL-path verify and no oracle
 *   distinguishes "wrong device" from "code exhausted".
 * - `not-found` — no row, or row expired. Caller surfaces as
 *   `INVALID_CODE`.
 *
 * Concurrency: the SELECT + UPDATE/DELETE pair runs inside a single
 * `db.transaction` so a racing second attempt cannot observe a stale
 * `attempts_remaining`. Postgres serializable isolation is not needed
 * — the row is locked for the transaction lifetime by the SELECT FOR
 * UPDATE.
 */
export const consumeMagicLinkCode = async (
  input: ConsumeMagicLinkCodeInput,
): Promise<ConsumeCodeOutcome> => {
  const codeIdentifier = deriveCodeIdentifier(input.code, input.secret);
  const wireFphB64Url = encodeBase64UrlNoPad(input.wireFingerprintHash);
  const wirePkB64 = encodeStandardBase64(input.wirePublicKeySPKI);
  return await db.transaction(async (tx) => {
    const now = new Date();
    const rows = await tx
      .select({
        fingerprintHash: magicLinkCode.fingerprintHash,
        publicKeySpki: magicLinkCode.publicKeySpki,
        attemptsRemaining: magicLinkCode.attemptsRemaining,
        plaintextToken: magicLinkCode.plaintextToken,
        tokenIdentifier: magicLinkCode.tokenIdentifier,
      })
      .from(magicLinkCode)
      .where(
        and(eq(magicLinkCode.codeIdentifier, codeIdentifier), gt(magicLinkCode.expiresAt, now)),
      )
      .for('update')
      .limit(1);
    const row = rows[0];
    if (row === undefined) {
      return { kind: 'not-found' } satisfies ConsumeCodeOutcome;
    }
    const isFphMatching = timingSafeStringEquals(row.fingerprintHash, wireFphB64Url);
    const isPkMatching = timingSafeStringEquals(row.publicKeySpki, wirePkB64);
    if (isFphMatching && isPkMatching) {
      await tx.delete(magicLinkCode).where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
      return {
        kind: 'match',
        plaintextToken: row.plaintextToken,
        tokenIdentifier: row.tokenIdentifier,
      } satisfies ConsumeCodeOutcome;
    }
    if (row.attemptsRemaining <= 1) {
      await tx.delete(magicLinkCode).where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
    } else {
      await tx
        .update(magicLinkCode)
        .set({ attemptsRemaining: sql`${magicLinkCode.attemptsRemaining} - 1` })
        .where(eq(magicLinkCode.codeIdentifier, codeIdentifier));
    }
    return { kind: 'mismatch' } satisfies ConsumeCodeOutcome;
  });
};

/**
 * Clear any backup-code row that points at the just-consumed magic-link
 * token. Called from the URL-path verify after-hook so the code path
 * cannot redeem a token that has already been minted into a session.
 *
 * Best-effort: a delete failure does not undo the URL verify — the row
 * expires naturally, and better-auth's `allowedAttempts: 1` blocks
 * replay at the verification-row layer.
 */
export const deleteMagicLinkCodeByTokenIdentifier = async (
  tokenIdentifier: string,
): Promise<void> => {
  await db.delete(magicLinkCode).where(eq(magicLinkCode.tokenIdentifier, tokenIdentifier));
};
