import { eq } from 'drizzle-orm';
import { user } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import { revokeAllGrantsForUser } from '~/lib/device-acl.ts';

/**
 * Permanently remove a user and every row that depends on them.
 *
 * The operation runs as a single transaction so the observable
 * outcome is all-or-nothing:
 *
 * 1. Every active `device_access_grant` row owned by the user is
 *    flipped to `revokedAt = now`. The per-slug
 *    `device_acl_revision` counter ticks for each affected device,
 *    so the next ACL poll from that device observes the change and
 *    disconnects any live TCP session the user's SE public key was
 *    driving.
 * 2. The `user` row is deleted. Cascade FKs drop:
 *    - every `session` row (and through it, every
 *      `session_attestation` and `idempotency_record`),
 *    - every `account` row (social provider linkage).
 *    `device_pairing_code.claimedByUserId` is set to NULL rather
 *    than cascading because the pairing ledger survives user
 *    deletion for fleet audit (the schema comment on that column
 *    documents this stance).
 *
 * Returns ``true`` when the user row existed and was deleted,
 * ``false`` when no row matched the id (already deleted, or a race
 * with a concurrent delete). The caller's middleware has already
 * validated the session, so a ``false`` return is a concurrency
 * edge, not a "user never existed" one — the handler still emits
 * the success response because the observable end state (no user
 * with this id) is identical.
 */
export const deleteUserAccount = async (input: {
  readonly userId: string;
  readonly now?: Date;
}): Promise<boolean> => {
  const now = input.now ?? new Date();
  return await db.transaction(async (tx) => {
    await revokeAllGrantsForUser(tx, { userId: input.userId, now });
    const deleted = await tx
      .delete(user)
      .where(eq(user.id, input.userId))
      .returning({ id: user.id });
    return deleted.length > 0;
  });
};
