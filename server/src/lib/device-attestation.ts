import { createPublicKey, timingSafeEqual, verify } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { device } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Ed25519 device-attestation — the authentication boundary for every
 * call a Catlaser daemon makes to the coordination server AFTER the
 * one-shot provisioning handshake.
 *
 * ## Why a separate scheme from the user `x-device-attestation`
 *
 * The `x-device-attestation` header defined in `attestation-header.ts`
 * authenticates *users* talking to protected API routes. It carries a
 * P-256 ECDSA signature under the iOS Secure Enclave key bound to the
 * sign-in session. Devices talking to the coordination server are a
 * different trust anchor: each physical Catlaser holds its own
 * Ed25519 key pair, generated at first boot and never exported. The
 * two systems never cross — a user session cannot impersonate a
 * device and vice versa — so they are encoded distinctly to prevent
 * header confusion.
 *
 * ## Wire format
 *
 * Three headers, all required on every device-to-server call:
 *
 * - `x-device-id: <slug>` — the `device.slug` the caller claims to
 *   be. Must match `[A-Za-z0-9_-]{1,64}` (same shape as the
 *   pairing-code `device_id`). The server looks this row up by slug.
 * - `x-device-timestamp: <unix_seconds>` — a signed Unix timestamp.
 *   The server enforces ±60 s skew against its own clock. A caller
 *   with a broken clock is rejected locally (the device-side
 *   plausible-clock check) before the call goes out.
 * - `x-device-signature: <base64-standard>` — Ed25519 signature over
 *   the canonical byte string
 *   `"dvc:" || METHOD || "\n" || pathname || "\n" || timestamp`,
 *   where `pathname` is the URL's path without query or fragment.
 *   Leading `"dvc:"` acts as a domain-separation tag so a captured
 *   signature cannot be replayed against a non-device endpoint that
 *   happens to sign a same-shape byte string.
 *
 * ## Server verification
 *
 * 1. Parse `x-device-id`. Missing, empty, or charset-invalid → 400.
 * 2. Parse `x-device-timestamp`. Non-integer, out of range, or more
 *    than 60 s from the server clock → 401.
 * 3. Parse `x-device-signature`. Not base64 or not 64 bytes → 401.
 * 4. Look up the `device` row by slug. Missing → 401.
 * 5. Reconstruct the signed bytes (method, path, timestamp) and
 *    verify the signature against the stored Ed25519 public key.
 *    Failure → 401.
 *
 * Every failure is a single machine-readable code; the handler layer
 * maps them to HTTP status codes. No failure path leaks which check
 * failed beyond the code itself.
 */

/** Header names. Lowercased for canonical matching. */
export const DEVICE_ID_HEADER = 'x-device-id';
export const DEVICE_TIMESTAMP_HEADER = 'x-device-timestamp';
export const DEVICE_SIGNATURE_HEADER = 'x-device-signature';

/**
 * Maximum skew between the device's claimed timestamp and the
 * server's clock. Matches the ±60 s window used by the user-side
 * `api:` attestation so captured headers cannot be replayed past this
 * bound.
 */
export const DEVICE_TIMESTAMP_SKEW_SECONDS = 60;

/**
 * Maximum Unix-seconds value any well-behaved device may legitimately
 * produce. 2100-01-01 UTC. Any request beyond this is a broken clock
 * or an intentional replay-farther-than-skew attempt — reject.
 */
export const DEVICE_TIMESTAMP_MAX = 4_102_444_800;

/**
 * Minimum Unix-seconds value any well-behaved device may legitimately
 * produce. 2020-01-01 UTC. Predates the product; earlier values are
 * broken clocks or replays.
 */
export const DEVICE_TIMESTAMP_MIN = 1_577_836_800;

/** Device-id charset: `[A-Za-z0-9_-]`, 1..64 chars. Mirrors the slug
 * constraint used by `device_pairing_code.device_id`. The hyphen is
 * positioned at the start of the character class so that the /v flag
 * does not interpret it as a range boundary between `\w` and the next
 * element. */
const DEVICE_SLUG_PATTERN = /^[\w\-]{1,64}$/v;

/**
 * Ed25519 public-key size in raw bytes. The stored SPKI in `device`
 * is the raw 32-byte key, base64url-no-pad encoded (matches the shape
 * the Python brain emits from its identity module).
 */
export const ED25519_PUBLIC_KEY_BYTES = 32;
/** Ed25519 signature size in bytes. */
export const ED25519_SIGNATURE_BYTES = 64;

/** SPKI prefix for a raw Ed25519 public key (RFC 8410 §4). Prepending
 * this 12-byte ASN.1 header to the 32-byte raw key yields the exact
 * DER-encoded `SubjectPublicKeyInfo` Node's `createPublicKey` expects
 * when `format: 'der'` and `type: 'spki'`. */
const ED25519_SPKI_PREFIX = Uint8Array.of(
  0x30,
  0x2a,
  0x30,
  0x05,
  0x06,
  0x03,
  0x2b,
  0x65,
  0x70,
  0x03,
  0x21,
  0x00,
);

export type DeviceAttestationCode =
  | 'DEVICE_ATTESTATION_REQUIRED'
  | 'DEVICE_ATTESTATION_DEVICE_ID_INVALID'
  | 'DEVICE_ATTESTATION_TIMESTAMP_INVALID'
  | 'DEVICE_ATTESTATION_SKEW_EXCEEDED'
  | 'DEVICE_ATTESTATION_SIGNATURE_INVALID'
  | 'DEVICE_ATTESTATION_DEVICE_NOT_REGISTERED';

export class DeviceAttestationError extends Error {
  public readonly code: DeviceAttestationCode;
  public readonly status: number;

  public constructor(code: DeviceAttestationCode, message: string, status = 401) {
    super(message);
    this.name = 'DeviceAttestationError';
    this.code = code;
    this.status = status;
  }
}

export interface VerifiedDeviceIdentity {
  readonly id: string;
  readonly slug: string;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
  readonly deviceName: string | null;
}

const decodeBase64Url = (value: string): Uint8Array | null => {
  let normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  const pad = normalized.length % 4;
  if (pad !== 0) {
    normalized += '='.repeat(4 - pad);
  }
  try {
    return Uint8Array.from(Buffer.from(normalized, 'base64'));
  } catch {
    return null;
  }
};

/**
 * Decode a stored Ed25519 public key. Handles both base64url-no-pad
 * (the canonical on-the-wire form the device emits) and standard
 * base64 with padding (a defensive fallback). Returns a 32-byte array
 * or null if the stored blob is malformed — the caller rejects as a
 * registration-integrity failure rather than blindly trying to
 * verify.
 */
const decodeStoredEd25519PublicKey = (stored: string): Uint8Array | null => {
  const raw = decodeBase64Url(stored);
  if (raw?.length !== ED25519_PUBLIC_KEY_BYTES) {
    return null;
  }
  return raw;
};

const decodeSignature = (stored: string): Uint8Array | null => {
  try {
    const buffer = Buffer.from(stored, 'base64');
    if (buffer.length !== ED25519_SIGNATURE_BYTES) {
      return null;
    }
    return Uint8Array.from(buffer);
  } catch {
    return null;
  }
};

const parseTimestamp = (raw: string): number | null => {
  const trimmed = raw.trim();
  if (trimmed.length === 0 || !/^\d+$/v.test(trimmed)) {
    return null;
  }
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value)) {
    return null;
  }
  return value;
};

/**
 * Canonical bytes signed by the device's Ed25519 key. The leading
 * `"dvc:"` tag forces domain separation from every other signing
 * surface in the system — a captured signature against this byte
 * string cannot be replayed as a user `api:` attestation (different
 * tag) or against a future device surface that changes the tag.
 *
 * Components separated by `\n`; method is ASCII uppercase; pathname
 * is the URL path (no query, no fragment). A timestamp is a plain
 * Unix-seconds integer in decimal. Every component is ASCII; no
 * escaping needed.
 */
export const buildDeviceSignedBytes = (
  method: string,
  pathname: string,
  timestamp: number,
): Uint8Array => {
  const body = `dvc:${method.toUpperCase()}\n${pathname}\n${timestamp.toString()}`;
  return new TextEncoder().encode(body);
};

/** Options for `verifyDeviceAttestedRequest`. Tests inject a frozen
 * clock so skew assertions are deterministic. */
export interface VerifyDeviceAttestedRequestOptions {
  readonly nowSeconds?: () => number;
}

/**
 * Verify the three device-attestation headers on an inbound request
 * and return the resolved device identity. Throws
 * `DeviceAttestationError` on any failure.
 *
 * Runs in order of increasing cost: structural checks first, DB
 * lookup and signature verify last. A missing header never touches
 * the database.
 */
interface ParsedDeviceHeaders {
  readonly slug: string;
  readonly timestamp: number;
  readonly signature: Uint8Array;
}

const readTrimmedHeader = (request: Request, name: string): string =>
  request.headers.get(name)?.trim() ?? '';

const assertDeviceSlug = (slug: string): void => {
  if (!DEVICE_SLUG_PATTERN.test(slug)) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_DEVICE_ID_INVALID',
      `device id must match /^[A-Za-z0-9_-]{1,64}$/`,
      400,
    );
  }
};

const parseDeviceTimestamp = (raw: string): number => {
  const timestamp = parseTimestamp(raw);
  if (timestamp === null || timestamp < DEVICE_TIMESTAMP_MIN || timestamp > DEVICE_TIMESTAMP_MAX) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_TIMESTAMP_INVALID',
      `device timestamp must be an integer between ${DEVICE_TIMESTAMP_MIN.toString()} and ${DEVICE_TIMESTAMP_MAX.toString()}`,
    );
  }
  return timestamp;
};

const parseDeviceSignature = (raw: string): Uint8Array => {
  const signature = decodeSignature(raw);
  if (signature === null) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_SIGNATURE_INVALID',
      `${DEVICE_SIGNATURE_HEADER} must be base64 of ${ED25519_SIGNATURE_BYTES.toString()} bytes`,
    );
  }
  return signature;
};

const parseDeviceHeaders = (request: Request): ParsedDeviceHeaders => {
  const slug = readTrimmedHeader(request, DEVICE_ID_HEADER);
  const tsHeader = readTrimmedHeader(request, DEVICE_TIMESTAMP_HEADER);
  const sigHeader = readTrimmedHeader(request, DEVICE_SIGNATURE_HEADER);
  if (slug.length === 0 || tsHeader.length === 0 || sigHeader.length === 0) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_REQUIRED',
      `missing one or more device-attestation headers: ${DEVICE_ID_HEADER}, ${DEVICE_TIMESTAMP_HEADER}, ${DEVICE_SIGNATURE_HEADER}`,
    );
  }
  assertDeviceSlug(slug);
  return {
    slug,
    timestamp: parseDeviceTimestamp(tsHeader),
    signature: parseDeviceSignature(sigHeader),
  };
};

const assertSkew = (timestamp: number, nowSeconds?: () => number): void => {
  const now = nowSeconds?.() ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - timestamp) > DEVICE_TIMESTAMP_SKEW_SECONDS) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_SKEW_EXCEEDED',
      `device timestamp outside ±${DEVICE_TIMESTAMP_SKEW_SECONDS.toString()} s skew window`,
    );
  }
};

interface StoredDeviceRow {
  readonly id: string;
  readonly slug: string;
  readonly publicKeyEd25519: string;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
  readonly deviceName: string | null;
}

const loadDeviceOrThrow = async (slug: string): Promise<StoredDeviceRow> => {
  const rows = await db
    .select({
      id: device.id,
      slug: device.slug,
      publicKeyEd25519: device.publicKeyEd25519,
      tailscaleHost: device.tailscaleHost,
      tailscalePort: device.tailscalePort,
      deviceName: device.deviceName,
    })
    .from(device)
    .where(eq(device.slug, slug))
    .limit(1);
  const row = rows[0];
  if (row === undefined) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_DEVICE_NOT_REGISTERED',
      'device slug not found in fleet',
    );
  }
  return row;
};

const loadDevicePublicKey = (storedPubKey: string): ReturnType<typeof createPublicKey> => {
  const rawKey = decodeStoredEd25519PublicKey(storedPubKey);
  if (rawKey === null) {
    // Corrupt row — caller should see the same generic "device not
    // registered" that hides fleet membership from an attacker.
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_DEVICE_NOT_REGISTERED',
      'stored device key is malformed',
    );
  }
  const spki = new Uint8Array(ED25519_SPKI_PREFIX.length + rawKey.length);
  spki.set(ED25519_SPKI_PREFIX, 0);
  spki.set(rawKey, ED25519_SPKI_PREFIX.length);
  return createPublicKey({ key: Buffer.from(spki), format: 'der', type: 'spki' });
};

export const verifyDeviceAttestedRequest = async (
  request: Request,
  options: VerifyDeviceAttestedRequestOptions = {},
): Promise<VerifiedDeviceIdentity> => {
  const parsed = parseDeviceHeaders(request);
  assertSkew(parsed.timestamp, options.nowSeconds);
  const row = await loadDeviceOrThrow(parsed.slug);
  const publicKey = loadDevicePublicKey(row.publicKeyEd25519);
  const url = new URL(request.url);
  const signed = buildDeviceSignedBytes(request.method, url.pathname, parsed.timestamp);
  // `verify(null, ...)` is Ed25519's default algorithm selection.
  const isValid = verify(null, signed, publicKey, parsed.signature);
  if (!isValid) {
    throw new DeviceAttestationError(
      'DEVICE_ATTESTATION_SIGNATURE_INVALID',
      'device signature did not verify under stored key',
    );
  }
  return {
    id: row.id,
    slug: row.slug,
    tailscaleHost: row.tailscaleHost,
    tailscalePort: row.tailscalePort,
    deviceName: row.deviceName,
  };
};

/**
 * Constant-time comparison for the bootstrap `PROVISIONING_TOKEN`
 * header on the one-shot provision call. Exposed so both the
 * provisioning route and its tests use the same helper.
 */
export const provisioningTokenMatches = (presented: string, expected: string): boolean => {
  const a = Buffer.from(presented, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (a.length !== b.length) {
    return false;
  }
  return timingSafeEqual(a, b);
};
