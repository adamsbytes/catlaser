import { createHash, randomUUID } from 'node:crypto';
import { and, eq, gt, lt } from 'drizzle-orm';
import { magicLinkAttestation } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Store and retrieve the `(fph, pk)` captured at `POST /sign-in/magic-link`
 * time so the `ver:` binding at `GET /magic-link/verify` can byte-compare
 * against what the original requesting device signed.
 *
 * This is the load-bearing half of BUILD.md Part 9 step 6 for the `ver:`
 * binding. Step 5 already validates the signature under the public key
 * present in the header — what this module adds is the invariant that the
 * verify-time public key and fingerprint hash are the EXACT ones the
 * request-time device used. Without it, an attacker who observed the
 * magic-link URL (email interception, shared email account, a device that
 * landed outside AASA routing) could sign a verify attestation under their
 * own Secure Enclave key and satisfy step 5 alone — step 5's crypto only
 * proves "some device signed this", not "the same device that requested".
 *
 * The stored identifier is `base64url-no-pad(sha256(magic_link_token))`,
 * byte-for-byte what better-auth's magic-link plugin stores in
 * `verification.identifier` when configured with `storeToken: 'hashed'`. This
 * means:
 *
 * - A DB leak exposes neither the plaintext token nor a value that the
 *   plaintext could be looked up by via a rainbow table — the token space is
 *   ~190 bits of unstructured entropy.
 * - The verify-time `ver:<token>` binding (where `token` is the plaintext
 *   from the URL) can be turned into a lookup key on the row by running
 *   `deriveTokenIdentifier(token)`. There is exactly one way to compute the
 *   identifier and both call sites (magic-link plugin + attestation plugin)
 *   use this function — so the hash parameters cannot drift between writer
 *   and reader.
 *
 * Rows expire alongside the magic-link token (default 5 minutes). Old rows
 * are cleaned up opportunistically on each insert; because the table is
 * short-lived and small, this is sufficient without a background cron.
 */

/**
 * Derive the database key for a magic-link token. SHA-256, base64url-no-pad,
 * matching the hash scheme better-auth uses internally with
 * `storeToken: 'hashed'`. Output is a 43-character ASCII string (32 bytes in
 * base64url-no-pad).
 */
export const deriveTokenIdentifier = (token: string): string =>
  createHash('sha256')
    .update(token, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/**
 * Fixed-size payload persisted and looked up. Encoded as strings for driver
 * portability; comparison on the verify path is string-level byte-equal and
 * remains constant-time via `node:crypto`'s `timingSafeEqual` over the UTF-8
 * encoding (see `attestation-plugin.ts`).
 */
export interface StoredMagicLinkAttestation {
  readonly fingerprintHashB64Url: string;
  readonly publicKeySpkiB64: string;
}

const encodeStandardBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');

const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeStandardBase64(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

/**
 * Write the attestation binding captured during `sendMagicLink`. Runs
 * inside the same request as the email delivery; an insert failure here
 * MUST propagate so the outgoing email is not sent under a missing row — a
 * subsequent verify would then DEVICE_MISMATCH and the user would be stuck.
 *
 * Takes the raw bytes from the parsed attestation so the string encoding
 * stays a storage-layer concern; callers never fabricate the base64 form.
 *
 * Any pre-existing row for the same token identifier is replaced (this
 * should be impossible in practice since the magic-link plugin rejects
 * duplicate tokens, but the overwrite guards against a prior failed request
 * leaving a partial row). The surrounding `magic_link_attestation_token_identifier_unique`
 * constraint enforces the one-row-per-token invariant.
 */
export const storeMagicLinkAttestation = async (input: {
  readonly tokenIdentifier: string;
  readonly fingerprintHash: Uint8Array;
  readonly publicKeySPKI: Uint8Array;
  readonly expiresAt: Date;
  readonly createdAt?: Date;
}): Promise<void> => {
  const createdAt = input.createdAt ?? new Date();
  const row = {
    id: randomUUID(),
    tokenIdentifier: input.tokenIdentifier,
    fingerprintHash: encodeBase64UrlNoPad(input.fingerprintHash),
    publicKeySpki: encodeStandardBase64(input.publicKeySPKI),
    expiresAt: input.expiresAt,
    createdAt,
  };
  await db
    .insert(magicLinkAttestation)
    .values(row)
    .onConflictDoUpdate({
      target: magicLinkAttestation.tokenIdentifier,
      set: {
        fingerprintHash: row.fingerprintHash,
        publicKeySpki: row.publicKeySpki,
        expiresAt: row.expiresAt,
        createdAt: row.createdAt,
      },
    });
  // Opportunistic housekeeping: drop any row whose magic-link token has
  // already expired. Keeps the table bounded in steady state without
  // requiring a background cron. Runs after the insert so a slow DELETE
  // never blocks the email-send hot path on success.
  await db.delete(magicLinkAttestation).where(lt(magicLinkAttestation.expiresAt, createdAt));
};

/**
 * Load the attestation payload captured at request time. Returns `null`
 * when the row is missing or has already expired — both cases resolve to
 * `DEVICE_MISMATCH` at the caller, because the verify-time device cannot
 * prove it signed the original request if the request-time record no
 * longer exists.
 *
 * Expiry is evaluated against the wall clock (`Date.now()`), not the
 * attestation-plugin's skew clock. Row `expires_at` is persisted as a
 * wall-clock value at `sendMagicLink` time, and the skew clock is a
 * test-only seam for exercising signature timestamp drift — the two are
 * unrelated concerns. Keeping the expiry filter pinned to real time means
 * a frozen-clock test (which drives `req:` / `out:` skew from a
 * deterministic offset) does not accidentally invalidate otherwise-fresh
 * stored rows.
 */
export const lookupMagicLinkAttestation = async (
  tokenIdentifier: string,
): Promise<StoredMagicLinkAttestation | null> => {
  const nowDate = new Date();
  // Strictly-greater-than comparison: a row expiring exactly at `now` is
  // treated as already-expired, keeping the boundary on the conservative
  // side for a security-sensitive lookup.
  const rows = await db
    .select({
      fingerprintHash: magicLinkAttestation.fingerprintHash,
      publicKeySpki: magicLinkAttestation.publicKeySpki,
    })
    .from(magicLinkAttestation)
    .where(
      and(
        eq(magicLinkAttestation.tokenIdentifier, tokenIdentifier),
        gt(magicLinkAttestation.expiresAt, nowDate),
      ),
    )
    .limit(1);
  const row = rows[0];
  if (row === undefined) {
    return null;
  }
  return {
    fingerprintHashB64Url: row.fingerprintHash,
    publicKeySpkiB64: row.publicKeySpki,
  };
};

/**
 * Remove the stored attestation row for a given magic-link token. Called
 * after a successful verify so the per-device binding row does not outlive
 * its purpose. A failure to delete here does not affect correctness — the
 * row expires naturally within the magic-link token lifetime, and the
 * plugin's `allowedAttempts: 1` means the corresponding verification row
 * cannot be replayed. The delete is therefore best-effort; callers must
 * not rely on the return value beyond diagnostic logging.
 */
export const deleteMagicLinkAttestation = async (tokenIdentifier: string): Promise<void> => {
  await db
    .delete(magicLinkAttestation)
    .where(eq(magicLinkAttestation.tokenIdentifier, tokenIdentifier));
};
