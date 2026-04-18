import { randomUUID } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { sessionAttestation } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Store and retrieve the per-session Secure-Enclave public key captured at
 * sign-in. This is the load-bearing half of BUILD.md Part 9 step 7 — the
 * "per-session SE pubkey stored at sign-in" artefact named in the ADR-006
 * decision record.
 *
 * On `/magic-link/verify` and `/sign-in/social`, the attestation plugin's
 * after-hook writes `(session_id, fph, pk)` here once better-auth has
 * created the session row. Both endpoints are already gated by the
 * attestation plugin's before-hook (structural parse, SPKI, binding tag,
 * ECDSA, nonce or stored-(fph, pk) match, ±60s skew), so the values stored
 * here are byte-identical to what the sign-in ceremony accepted.
 *
 * On every protected-route call, `requireAttestedSession` in
 * `protected-route.ts` looks up this row by the resolved session's id and
 * verifies the ECDSA signature against the stored SPKI. Verifying under the
 * stored key — not the wire key — is the defence that makes a captured
 * bearer insufficient to act: an attacker with the bearer but without the
 * Secure Enclave's non-extractable private key cannot produce a fresh `api:`
 * attestation that verifies under the stored pk, regardless of what pk they
 * send on the wire.
 *
 * 1:1 with `session` via the unique `session_id` FK. `ON DELETE CASCADE`
 * keeps the row's lifetime equal to the session's — sign-out, session
 * revoke, or user delete drops this row atomically, so a stale row never
 * outlives its owning session.
 */

export interface StoredSessionAttestation {
  readonly fingerprintHashB64Url: string;
  readonly publicKeySpkiB64: string;
}

const encodeStandardBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');

const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeStandardBase64(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

/**
 * Write the attestation binding captured at sign-in. Upsert on the
 * `session_id` unique constraint so a retried sign-in (which better-auth
 * guards against at a higher layer) cannot leave an orphan row.
 *
 * Takes raw bytes so the string encoding stays a storage-layer concern;
 * callers never fabricate the base64 form. The `createdAt` override is
 * the test-clock seam — production always writes wall time.
 */
export const storeSessionAttestation = async (input: {
  readonly sessionId: string;
  readonly fingerprintHash: Uint8Array;
  readonly publicKeySPKI: Uint8Array;
  readonly createdAt?: Date;
}): Promise<void> => {
  const createdAt = input.createdAt ?? new Date();
  const row = {
    id: randomUUID(),
    sessionId: input.sessionId,
    fingerprintHash: encodeBase64UrlNoPad(input.fingerprintHash),
    publicKeySpki: encodeStandardBase64(input.publicKeySPKI),
    createdAt,
  };
  await db
    .insert(sessionAttestation)
    .values(row)
    .onConflictDoUpdate({
      target: sessionAttestation.sessionId,
      set: {
        fingerprintHash: row.fingerprintHash,
        publicKeySpki: row.publicKeySpki,
        createdAt: row.createdAt,
      },
    });
};

/**
 * Load the attestation bound to a session at sign-in. Returns `null` if no
 * row exists — the protected-route middleware treats that as
 * `SESSION_ATTESTATION_MISSING` and rejects with 401.
 *
 * No expiry check is needed here: the `ON DELETE CASCADE` on `session_id`
 * means the row lives exactly as long as the owning session. A session
 * that has expired or been revoked will not resolve via
 * `auth.api.getSession` in the first place, so the middleware never reaches
 * this lookup with a stale session id.
 */
export const lookupSessionAttestation = async (
  sessionId: string,
): Promise<StoredSessionAttestation | null> => {
  const rows = await db
    .select({
      fingerprintHash: sessionAttestation.fingerprintHash,
      publicKeySpki: sessionAttestation.publicKeySpki,
    })
    .from(sessionAttestation)
    .where(eq(sessionAttestation.sessionId, sessionId))
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
