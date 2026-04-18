import { randomUUID } from 'node:crypto';
import { and, eq, isNull, ne, sql } from 'drizzle-orm';
import { deviceAccessGrant, deviceAclRevision, sessionAttestation } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Device ACL — the authorization list each Catlaser daemon polls
 * from the coordination server to decide which iOS app connections
 * to accept.
 *
 * ## Who writes here
 *
 * - `exchangePairingCode` (pair claim) inserts or unrevokes a grant
 *   for `(device_slug, user_spki)` where `user_spki` is the claiming
 *   session's `session_attestation.public_key_spki`. It also revokes
 *   every other active grant for the same `device_slug` (different
 *   user), so the ACL is single-owner the moment a pair is claimed.
 * - (Future) A sign-out / unpair handler may write a targeted revoke
 *   without a re-pair. Today the pair claim is the only write path.
 *
 * ## Who reads here
 *
 * - `GET /api/v1/devices/:slug/acl`, gated by device-attestation.
 *   Returns the set of active `user_spki` for the caller's slug plus
 *   the current revision. The Python brain polls this every minute
 *   and rejects any inbound TCP handshake whose user SPKI isn't in
 *   the cached set.
 *
 * ## Revision semantics
 *
 * Every write against `device_access_grant` for a given `device_slug`
 * also increments `device_acl_revision.revision` for that slug
 * (inside the same transaction). Pollers can later use the revision
 * to short-circuit unchanged responses, and the revision is the
 * authoritative ordering signal if the server ever ships multiple
 * revisions in flight to a single device (today: one poll at a time,
 * but the column is there so the contract is stable).
 */

/**
 * Result of looking up a session's SPKI for the ACL write path. If
 * the session has no `session_attestation` row, the pair claim
 * cannot safely publish an ACL entry and the caller must fail the
 * whole claim. This should never happen in practice — sign-in writes
 * the row atomically — but the null-return gives the caller a seam
 * to surface a concrete error.
 */
export const loadSessionSpki = async (sessionId: string): Promise<string | null> => {
  const rows = await db
    .select({ publicKeySpkiB64: sessionAttestation.publicKeySpki })
    .from(sessionAttestation)
    .where(eq(sessionAttestation.sessionId, sessionId))
    .limit(1);
  return rows[0]?.publicKeySpkiB64 ?? null;
};

/**
 * Bump the monotonic revision counter for `deviceSlug`. Runs inside
 * the caller's transaction. Returns the new revision.
 *
 * Implementation note: Postgres has no sequence per-composite-key,
 * so we maintain a single-row table `device_acl_revision` keyed by
 * slug. `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` gives us an
 * atomic "read-modify-write, returning the new value" primitive.
 */
const bumpRevision = async (
  tx: Parameters<Parameters<typeof db.transaction>[0]>[0],
  deviceSlug: string,
  now: Date,
): Promise<number> => {
  const rows = await tx
    .insert(deviceAclRevision)
    .values({ deviceSlug, revision: 1, updatedAt: now })
    .onConflictDoUpdate({
      target: deviceAclRevision.deviceSlug,
      set: {
        revision: sql`${deviceAclRevision.revision} + 1`,
        updatedAt: now,
      },
    })
    .returning({ revision: deviceAclRevision.revision });
  const row = rows[0];
  if (row === undefined) {
    throw new Error('bumpRevision unreachable: upsert returned zero rows');
  }
  return row.revision;
};

export interface PublishPairGrantInput {
  readonly deviceSlug: string;
  readonly userSpkiB64: string;
  readonly userId: string;
  readonly now: Date;
}

/**
 * Write the pair-claim ACL change atomically:
 *
 * 1. Revoke every active grant for `deviceSlug` whose
 *    `user_spki_b64` is NOT the caller's — a newly claimed device
 *    belongs to exactly one user.
 * 2. Upsert the claimant's grant: if the row exists (revoked or
 *    active), re-activate it and update `userId`/`grantedAt`; if
 *    it doesn't exist, insert it.
 * 3. Bump the per-slug revision counter.
 *
 * MUST be called inside the same transaction as the
 * `device_pairing_code` update, so a failure on either side rolls
 * back cleanly and the ACL cannot drift from the pair-claim ledger.
 * The `tx` parameter is the Drizzle transaction handle; passing
 * `db` directly works too but loses the all-or-nothing guarantee.
 */
export const publishPairGrant = async (
  tx: Parameters<Parameters<typeof db.transaction>[0]>[0],
  input: PublishPairGrantInput,
): Promise<{ readonly revision: number }> => {
  // Revoke active grants for this device held by OTHER users.
  await tx
    .update(deviceAccessGrant)
    .set({ revokedAt: input.now })
    .where(
      and(
        eq(deviceAccessGrant.deviceSlug, input.deviceSlug),
        ne(deviceAccessGrant.userSpkiB64, input.userSpkiB64),
        isNull(deviceAccessGrant.revokedAt),
      ),
    );

  // Upsert the claimant's grant. `ON CONFLICT (device_slug,
  // user_spki_b64) DO UPDATE` handles the re-grant-after-revoke
  // case cleanly: revoked row flips back to active, and the
  // `grantedAt`/`userId` are refreshed.
  const revision = await bumpRevision(tx, input.deviceSlug, input.now);
  const id = randomUUID();
  await tx
    .insert(deviceAccessGrant)
    .values({
      id,
      deviceSlug: input.deviceSlug,
      userSpkiB64: input.userSpkiB64,
      userId: input.userId,
      grantedAt: input.now,
      revokedAt: null,
      revision,
    })
    .onConflictDoUpdate({
      target: [deviceAccessGrant.deviceSlug, deviceAccessGrant.userSpkiB64],
      set: {
        userId: input.userId,
        grantedAt: input.now,
        revokedAt: null,
        revision,
      },
    });
  return { revision };
};

/**
 * ACL row shape returned to the polling device. Only active grants
 * appear; revoked rows are filtered out at the SELECT layer.
 */
export interface ActiveGrant {
  readonly userSpkiB64: string;
  readonly revision: number;
  readonly grantedAt: Date;
}

export interface DeviceAcl {
  readonly deviceSlug: string;
  readonly revision: number;
  readonly grants: readonly ActiveGrant[];
}

/**
 * Read the current ACL for `deviceSlug`. Returns the list of active
 * grants (by user SPKI) plus the per-slug revision. A slug with
 * zero grants still returns an `ok` ACL with an empty list — the
 * caller can distinguish that from "device not registered" via the
 * upstream device-attestation check.
 */
export const readDeviceAcl = async (deviceSlug: string): Promise<DeviceAcl> => {
  const [rev] = await db
    .select({ revision: deviceAclRevision.revision })
    .from(deviceAclRevision)
    .where(eq(deviceAclRevision.deviceSlug, deviceSlug))
    .limit(1);
  const revision = rev?.revision ?? 0;
  const grants = await db
    .select({
      userSpkiB64: deviceAccessGrant.userSpkiB64,
      revision: deviceAccessGrant.revision,
      grantedAt: deviceAccessGrant.grantedAt,
    })
    .from(deviceAccessGrant)
    .where(and(eq(deviceAccessGrant.deviceSlug, deviceSlug), isNull(deviceAccessGrant.revokedAt)))
    .orderBy(sql`${deviceAccessGrant.revision} DESC`);
  return {
    deviceSlug,
    revision,
    grants: grants.map((row) => ({
      userSpkiB64: row.userSpkiB64,
      revision: row.revision,
      grantedAt: row.grantedAt,
    })),
  };
};
