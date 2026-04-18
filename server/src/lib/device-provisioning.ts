import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { device } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import { ED25519_PUBLIC_KEY_BYTES } from '~/lib/device-attestation.ts';
import {
  MAX_DEVICE_ID_LENGTH,
  MAX_TAILSCALE_PORT,
  MIN_TAILSCALE_PORT,
  isPlausibleTailscaleHost,
  validateDeviceId,
} from '~/lib/device-pairing.ts';

/**
 * Factory-time device registration. Owns the `device` table.
 *
 * `POST /api/v1/devices/provision` is the one and only endpoint that
 * introduces a fresh physical Catlaser to the coordination server's
 * fleet. It is authenticated by a pre-shared `PROVISIONING_TOKEN`
 * (not by device attestation — the device's Ed25519 key is WHAT this
 * call publishes, so attestation would be circular). Every
 * subsequent device-to-server call is authenticated by the published
 * Ed25519 key through `verifyDeviceAttestedRequest`.
 *
 * The endpoint is idempotent on `slug`: a re-provision with the same
 * slug updates the stored public key, tailnet host/port, and
 * device_name. This is deliberate — a device that has its filesystem
 * wiped and re-generates its identity must be able to re-register
 * without operator-side cleanup. A rotation like that is rare (full
 * factory reset) but must be supported without an out-of-band
 * migration.
 *
 * Consequences of accepting key rotation on re-provision:
 *
 * - Any existing `device_access_grant` rows for this slug are still
 *   valid after the rotation (the ACL is keyed on user SPKI, not on
 *   the device key). The device will continue to accept the same
 *   users once its ACL poller picks up the list.
 * - Any in-flight user app connections under the OLD device key will
 *   continue using the cached ACL until the device daemon is
 *   restarted; but since the device can't talk to the coordination
 *   server under the old key after rotation (the server now holds
 *   the new key), the old daemon's ACL will go stale and eventually
 *   fail verification on a poll retry — which causes the daemon to
 *   restart per its usual supervision. The user-facing effect is at
 *   most one dropped TCP session; no cross-user confusion is
 *   possible because the ACL is still keyed on user SPKI.
 */

/**
 * Accepted device-name cap. Matches the pairing-code `device_name`
 * limit (1..128 chars when provided) so a name accepted at
 * provisioning round-trips cleanly through `issuePairingCode`.
 */
export const MAX_DEVICE_NAME_LENGTH = 128;

export type ProvisioningValidationError =
  | 'DEVICE_SLUG_REQUIRED'
  | 'DEVICE_SLUG_INVALID'
  | 'PUBLIC_KEY_REQUIRED'
  | 'PUBLIC_KEY_INVALID'
  | 'TAILSCALE_HOST_INVALID'
  | 'TAILSCALE_PORT_INVALID'
  | 'DEVICE_NAME_INVALID';

export class DeviceProvisioningError extends Error {
  public readonly code: ProvisioningValidationError;

  public constructor(code: ProvisioningValidationError, message: string) {
    super(`invalid device-provision input: ${code} — ${message}`);
    this.name = 'DeviceProvisioningError';
    this.code = code;
  }
}

/**
 * Decode a base64url-no-pad Ed25519 public key. Returns the raw
 * 32-byte key on success, null on any parse or length failure. The
 * caller maps `null` into `PUBLIC_KEY_INVALID`.
 */
const decodeBase64UrlStrict = (value: string): Uint8Array | null => {
  if (!/^[\w\-]+$/v.test(value)) {
    return null;
  }
  let normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  const pad = normalized.length % 4;
  if (pad !== 0) {
    normalized += '='.repeat(4 - pad);
  }
  try {
    const buffer = Buffer.from(normalized, 'base64');
    return Uint8Array.from(buffer);
  } catch {
    return null;
  }
};

export interface ProvisionDeviceInput {
  readonly slug: string;
  readonly publicKeyEd25519: string;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
  readonly deviceName?: string | null;
  readonly now?: Date;
}

export interface ProvisionDeviceResult {
  readonly id: string;
  readonly slug: string;
  readonly isNew: boolean;
}

const assertSlug = (slug: string): void => {
  if (slug.length === 0) {
    throw new DeviceProvisioningError('DEVICE_SLUG_REQUIRED', 'slug must not be empty');
  }
  const slugError = validateDeviceId(slug);
  if (slugError !== null) {
    throw new DeviceProvisioningError('DEVICE_SLUG_INVALID', slugError);
  }
  if (slug.length > MAX_DEVICE_ID_LENGTH) {
    throw new DeviceProvisioningError(
      'DEVICE_SLUG_INVALID',
      `slug length ${slug.length.toString()} exceeds max ${MAX_DEVICE_ID_LENGTH.toString()}`,
    );
  }
};

const assertPublicKey = (publicKeyEd25519: string): Uint8Array => {
  if (publicKeyEd25519.length === 0) {
    throw new DeviceProvisioningError(
      'PUBLIC_KEY_REQUIRED',
      'public_key_ed25519 must not be empty',
    );
  }
  const decoded = decodeBase64UrlStrict(publicKeyEd25519);
  if (decoded?.length !== ED25519_PUBLIC_KEY_BYTES) {
    throw new DeviceProvisioningError(
      'PUBLIC_KEY_INVALID',
      `public_key_ed25519 must be base64url of exactly ${ED25519_PUBLIC_KEY_BYTES.toString()} bytes`,
    );
  }
  return decoded;
};

const assertTailscaleEndpoint = (host: string, port: number): void => {
  if (!isPlausibleTailscaleHost(host)) {
    throw new DeviceProvisioningError(
      'TAILSCALE_HOST_INVALID',
      'tailscale_host must be a Tailscale address (CGNAT IPv4, Tailscale IPv6, or MagicDNS)',
    );
  }
  if (!Number.isInteger(port) || port < MIN_TAILSCALE_PORT || port > MAX_TAILSCALE_PORT) {
    throw new DeviceProvisioningError(
      'TAILSCALE_PORT_INVALID',
      `tailscale_port must be an integer in [${MIN_TAILSCALE_PORT.toString()}, ${MAX_TAILSCALE_PORT.toString()}]`,
    );
  }
};

const assertDeviceName = (deviceName: string | null | undefined): void => {
  if (deviceName === undefined || deviceName === null) {
    return;
  }
  const trimmed = deviceName.trim();
  if (trimmed.length === 0 || trimmed.length > MAX_DEVICE_NAME_LENGTH) {
    throw new DeviceProvisioningError(
      'DEVICE_NAME_INVALID',
      `device_name must be 1..${MAX_DEVICE_NAME_LENGTH.toString()} chars (after trim)`,
    );
  }
};

const assertValid = (input: ProvisionDeviceInput): Uint8Array => {
  assertSlug(input.slug);
  const decoded = assertPublicKey(input.publicKeyEd25519);
  assertTailscaleEndpoint(input.tailscaleHost, input.tailscalePort);
  assertDeviceName(input.deviceName);
  return decoded;
};

/**
 * Upsert a `device` row. Matches on `slug`; updates public key,
 * tailnet host/port, and device_name when the row exists. Returns
 * `isNew=true` only when the row was freshly inserted — a
 * re-provision of an existing slug returns `isNew=false`.
 *
 * Runs atomically via `INSERT ... ON CONFLICT ... DO UPDATE`.
 */
export const provisionDevice = async (
  input: ProvisionDeviceInput,
): Promise<ProvisionDeviceResult> => {
  assertValid(input);
  const now = input.now ?? new Date();
  const id = randomUUID();
  // `xmax = 0` in the RETURNING clause is Postgres-specific shorthand
  // for "this row was inserted, not updated" — the conflict path sets
  // xmax to a non-zero txid on the target row. Cheap way to
  // distinguish insert from upsert without a second round-trip.
  const rows = await db
    .insert(device)
    .values({
      id,
      slug: input.slug,
      publicKeyEd25519: input.publicKeyEd25519,
      tailscaleHost: input.tailscaleHost,
      tailscalePort: input.tailscalePort,
      deviceName: input.deviceName ?? null,
      registeredAt: now,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: device.slug,
      set: {
        publicKeyEd25519: input.publicKeyEd25519,
        tailscaleHost: input.tailscaleHost,
        tailscalePort: input.tailscalePort,
        deviceName: input.deviceName ?? null,
        updatedAt: now,
      },
    })
    .returning({
      id: device.id,
      slug: device.slug,
      isNew: sql<boolean>`(xmax = 0)`,
    });
  const row = rows[0];
  if (row === undefined) {
    throw new Error('provisionDevice unreachable: upsert returned zero rows');
  }
  return { id: row.id, slug: row.slug, isNew: row.isNew };
};

/** Validate the `PROVISIONING_TOKEN` header (`x-provisioning-token`).
 * Constant-time compare. Re-exported from `device-attestation.ts`'s
 * helper so call sites use the same primitive regardless of which
 * verification path they touch. */
export const PROVISIONING_TOKEN_HEADER = 'x-provisioning-token';
export { provisioningTokenMatches } from '~/lib/device-attestation.ts';
