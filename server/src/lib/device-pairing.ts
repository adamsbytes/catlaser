import { createHash, randomUUID } from 'node:crypto';
import { and, eq, isNull, lt, ne, sql } from 'drizzle-orm';
import { devicePairingCode } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';

/**
 * Device-pairing domain — the bridge between a QR the app scanned and
 * the reachable Tailscale endpoint of a provisioned device.
 *
 * This module owns three invariants:
 *
 * 1. The plaintext pairing code never lands in the database. Rows key on
 *    `base64url-no-pad(sha256(code))`; a compromise of the ledger is not
 *    redeemable into a valid pairing without the physical QR.
 * 2. The claim is atomic. `exchangePairingCode` issues a single
 *    `UPDATE ... WHERE code_hash = $1 AND device_id = $2 AND claimed_at
 *    IS NULL AND expires_at > $now RETURNING ...`; on a zero-row result,
 *    a follow-up classifying `SELECT` distinguishes unknown / expired /
 *    already-claimed / device-mismatch. Two concurrent claims against
 *    the same code resolve as one success and one `ALREADY_USED`.
 * 3. Device-id mismatches collapse to `NOT_FOUND` at the caller. An
 *    attacker who POSTs a guessed code paired with an arbitrary
 *    `device_id` would otherwise get a signal distinguishing "valid code
 *    exists under a different device" from "code not in the ledger".
 *    Returning a single bucket means a captured QR is the only way to
 *    probe the space.
 *
 * The module stays decoupled from HTTP: `exchangePairingCode` returns a
 * discriminated union of outcomes, and the route layer maps those to
 * status codes. That way the idempotency gate's cached-response machinery
 * sees a stable function of inputs, not a response-construction concern.
 */

/**
 * Default pairing-code lifetime. A device's first-boot QR is expected to
 * be scanned within minutes of provisioning, not hours — 15 minutes is
 * generous enough to cover a distracted user, tight enough that a
 * discarded paper scrap with the QR on it is not a durable credential.
 * Re-issuance is cheap (the device shows a fresh QR on demand), so
 * nothing is gained by stretching this window.
 */
export const DEVICE_PAIRING_CODE_TTL_SECONDS = 15 * 60;

/**
 * Accepted character set for the opaque pairing-code secret. Matches the
 * iOS `PairingCode.validateCode` contract byte-for-byte: RFC 4648 base32
 * uppercase alphabet + digits 2..7, no padding, 16..128 characters. The
 * server is authoritative over issuance format — the iOS check is a
 * client-side pre-filter — but the bracket matches so a QR that made it
 * past the app's parser cannot surprise the server with an "unexpected"
 * shape, and a change to either side surfaces as a test failure, not as
 * silent drift.
 */
export const MIN_PAIRING_CODE_LENGTH = 16;
export const MAX_PAIRING_CODE_LENGTH = 128;

/**
 * Accepted character set for the device slug. Mirrors the iOS
 * `PairingCode.validateDeviceID` rules: `[A-Za-z0-9_-]`, 1..64 chars.
 * Device slugs are derived from the stable serial at provisioning — the
 * exact scheme is server-owned — but any slug the server issues must fit
 * this shape so the client and server agree on what is legal to send.
 */
export const MAX_DEVICE_ID_LENGTH = 64;

/**
 * DNS/IP host validator for `tailscale_host`. Accepts RFC 1035 DNS
 * names, IPv4 dotted-quad, and IPv6 literals — the same surface the iOS
 * `DeviceEndpoint.isPlausibleHost` accepts, so a host that survived
 * issuance can always be constructed by the client on the other side of
 * the round-trip. Rejects URL syntax (scheme/path/port/userinfo
 * smuggling), whitespace, and non-ASCII bytes.
 *
 * Implemented as character-by-character scans rather than regex to
 * avoid ReDoS surface and to keep the charset allowlist greppable. The
 * two callers — provisioning (untrusted in principle; these are server
 * operators in practice) and the round-trip test harness — both run
 * once per request, so the loop cost is irrelevant.
 */

/**
 * Maximum host length. RFC 1035 caps a DNS name at 253 octets; bracketed
 * IPv6 with zone identifiers stays well under that. The ceiling is a
 * conservative input-size gate, not a correctness constraint.
 */
export const MAX_TAILSCALE_HOST_LENGTH = 253;

const isAsciiDigit = (code: number): boolean => code >= 0x30 && code <= 0x39;
const isAsciiAlpha = (code: number): boolean =>
  (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
const isAsciiHex = (code: number): boolean =>
  isAsciiDigit(code) || (code >= 0x41 && code <= 0x46) || (code >= 0x61 && code <= 0x66);

const everyCodePoint = (value: string, predicate: (code: number) => boolean): boolean => {
  for (const char of value) {
    const code = char.codePointAt(0);
    if (code === undefined || !predicate(code)) {
      return false;
    }
  }
  return true;
};

const isDnsLabelChar = (code: number): boolean =>
  isAsciiDigit(code) || isAsciiAlpha(code) || code === 0x2d;

const isDnsLabel = (label: string): boolean => {
  if (label.length === 0 || label.length > 63) {
    return false;
  }
  if (label.startsWith('-') || label.endsWith('-')) {
    return false;
  }
  return everyCodePoint(label, isDnsLabelChar);
};

const isIpv6AddressChar = (code: number): boolean =>
  isAsciiHex(code) || code === 0x3a || code === 0x2e;

const isIpv6ZoneChar = (code: number): boolean =>
  isAsciiDigit(code) || isAsciiAlpha(code) || code === 0x2d || code === 0x2e || code === 0x5f;

const isIpv6Literal = (candidate: string): boolean => {
  // Only the charset is asserted here, not a full RFC 4291 parse: the
  // address is stored verbatim and handed to the client, which
  // re-validates via `DeviceEndpoint` before opening a socket.
  const zoneIndex = candidate.indexOf('%');
  const address = zoneIndex === -1 ? candidate : candidate.slice(0, zoneIndex);
  if (address.length === 0 || !everyCodePoint(address, isIpv6AddressChar)) {
    return false;
  }
  if (zoneIndex === -1) {
    return true;
  }
  const zone = candidate.slice(zoneIndex + 1);
  return zone.length > 0 && everyCodePoint(zone, isIpv6ZoneChar);
};

const stripIpv6Brackets = (candidate: string): string =>
  candidate.startsWith('[') && candidate.endsWith(']') ? candidate.slice(1, -1) : candidate;

const isDnsName = (candidate: string): boolean => {
  const labels = candidate.split('.');
  if (labels.length === 0 || labels.some((label) => label.length === 0)) {
    return false;
  }
  return labels.every((label) => isDnsLabel(label));
};

const isPlausibleTailscaleHost = (candidate: string): boolean => {
  if (candidate.length === 0 || candidate.length > MAX_TAILSCALE_HOST_LENGTH) {
    return false;
  }
  const inner = stripIpv6Brackets(candidate);
  if (inner.length === 0) {
    return false;
  }
  return inner.includes(':') ? isIpv6Literal(inner) : isDnsName(inner);
};

/**
 * TCP port range per IANA. Zero is invalid (per RFC 6335 it is the
 * wildcard for "any available port" at bind time and is not a legal
 * destination); the upper bound is a plain uint16.
 */
export const MIN_TAILSCALE_PORT = 1;
export const MAX_TAILSCALE_PORT = 65_535;

export type PairingCodeValidationError =
  | 'CODE_REQUIRED'
  | 'CODE_TOO_SHORT'
  | 'CODE_TOO_LONG'
  | 'CODE_CHARSET_INVALID';

export type DeviceIdValidationError =
  | 'DEVICE_ID_REQUIRED'
  | 'DEVICE_ID_TOO_LONG'
  | 'DEVICE_ID_CHARSET_INVALID';

const CODE_ALPHABET = /^[2-7A-Z]+$/v;

export const validatePairingCode = (candidate: string): PairingCodeValidationError | null => {
  if (candidate.length === 0) {
    return 'CODE_REQUIRED';
  }
  if (candidate.length < MIN_PAIRING_CODE_LENGTH) {
    return 'CODE_TOO_SHORT';
  }
  if (candidate.length > MAX_PAIRING_CODE_LENGTH) {
    return 'CODE_TOO_LONG';
  }
  if (!CODE_ALPHABET.test(candidate)) {
    return 'CODE_CHARSET_INVALID';
  }
  return null;
};

const isDeviceIdChar = (code: number): boolean =>
  isAsciiDigit(code) || isAsciiAlpha(code) || code === 0x2d || code === 0x5f;

export const validateDeviceId = (candidate: string): DeviceIdValidationError | null => {
  if (candidate.length === 0) {
    return 'DEVICE_ID_REQUIRED';
  }
  if (candidate.length > MAX_DEVICE_ID_LENGTH) {
    return 'DEVICE_ID_TOO_LONG';
  }
  for (const char of candidate) {
    const code = char.codePointAt(0);
    if (code === undefined || !isDeviceIdChar(code)) {
      return 'DEVICE_ID_CHARSET_INVALID';
    }
  }
  return null;
};

/**
 * Hash a plaintext pairing code for DB storage / lookup. SHA-256,
 * base64url-no-pad — mirrors `deriveTokenIdentifier` in
 * `magic-link-attestation.ts`. A 160-bit input is already well above the
 * threshold where plain SHA-256 suffices against rainbow-table probes.
 */
export const hashPairingCode = (code: string): string =>
  createHash('sha256')
    .update(code, 'utf8')
    .digest('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/**
 * Payload written by the provisioning pipeline (or a test) when a device
 * registers a fresh pairing code. The plaintext `code` leaves this
 * module immediately after hashing; callers must not log or persist it
 * alongside the stored row. `expiresAt` defaults to
 * `now + DEVICE_PAIRING_CODE_TTL_SECONDS` when omitted.
 */
export interface IssuePairingCodeInput {
  readonly code: string;
  readonly deviceId: string;
  readonly deviceName?: string;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
  readonly expiresAt?: Date;
  readonly createdAt?: Date;
}

export class PairingCodeIssueError extends Error {
  public readonly field: string;
  public readonly reason: string;

  public constructor(field: string, reason: string) {
    super(`invalid pairing code issuance: ${field} — ${reason}`);
    this.name = 'PairingCodeIssueError';
    this.field = field;
    this.reason = reason;
  }
}

const assertValidIssuance = (input: IssuePairingCodeInput): void => {
  const codeError = validatePairingCode(input.code);
  if (codeError !== null) {
    throw new PairingCodeIssueError('code', codeError);
  }
  const deviceError = validateDeviceId(input.deviceId);
  if (deviceError !== null) {
    throw new PairingCodeIssueError('deviceId', deviceError);
  }
  if (!isPlausibleTailscaleHost(input.tailscaleHost)) {
    throw new PairingCodeIssueError('tailscaleHost', 'not a plausible DNS name or IP literal');
  }
  if (
    !Number.isInteger(input.tailscalePort) ||
    input.tailscalePort < MIN_TAILSCALE_PORT ||
    input.tailscalePort > MAX_TAILSCALE_PORT
  ) {
    throw new PairingCodeIssueError(
      'tailscalePort',
      `must be integer in [${MIN_TAILSCALE_PORT.toString()}, ${MAX_TAILSCALE_PORT.toString()}]`,
    );
  }
  if (
    input.deviceName !== undefined &&
    (input.deviceName.length === 0 || input.deviceName.length > 128)
  ) {
    throw new PairingCodeIssueError('deviceName', 'must be 1..128 characters when provided');
  }
};

/**
 * Persist a fresh pairing-code row. Returns the stored `id` so callers
 * that want to correlate server-side can do so without a follow-up
 * query. The `codeHash` is surfaced as well to keep the read-path
 * symmetric; plaintext `code` never leaves the caller stack.
 *
 * Runs opportunistic housekeeping after the insert: drops any already-
 * expired unclaimed row. Keeps the table bounded in steady state without
 * requiring a background cron.
 */
export const issuePairingCode = async (
  input: IssuePairingCodeInput,
): Promise<{ readonly id: string; readonly codeHash: string }> => {
  assertValidIssuance(input);
  const createdAt = input.createdAt ?? new Date();
  const expiresAt =
    input.expiresAt ?? new Date(createdAt.getTime() + DEVICE_PAIRING_CODE_TTL_SECONDS * 1000);
  const codeHash = hashPairingCode(input.code);
  const id = randomUUID();
  await db.insert(devicePairingCode).values({
    id,
    codeHash,
    deviceId: input.deviceId,
    deviceName: input.deviceName ?? null,
    tailscaleHost: input.tailscaleHost,
    tailscalePort: input.tailscalePort,
    expiresAt,
    claimedAt: null,
    claimedByUserId: null,
    createdAt,
  });
  // Housekeeping: drop rows whose pairing window has elapsed and which
  // were never claimed. A claimed row is left alone — it retains audit
  // value for fleet diagnostics. The just-inserted row is explicitly
  // excluded so test fixtures that seed an already-expired row (to
  // exercise the 410 path) don't cannibalise themselves; in production
  // a fresh row always has `expiresAt = createdAt + TTL` and the
  // exclusion is a no-op.
  await db
    .delete(devicePairingCode)
    .where(
      and(
        lt(devicePairingCode.expiresAt, createdAt),
        isNull(devicePairingCode.claimedAt),
        ne(devicePairingCode.id, id),
      ),
    );
  return { id, codeHash };
};

/**
 * Resolved device endpoint returned to a paired caller.
 */
export interface PairedDeviceRecord {
  readonly deviceId: string;
  readonly deviceName: string | null;
  readonly host: string;
  readonly port: number;
}

/**
 * Classifying outcome produced by `exchangePairingCode`. The route layer
 * maps these onto HTTP status codes; the caller never fabricates one.
 */
export type ExchangeOutcome =
  | { readonly kind: 'ok'; readonly device: PairedDeviceRecord }
  | { readonly kind: 'not_found' }
  | { readonly kind: 'expired' }
  | { readonly kind: 'already_used' };

export interface ExchangePairingCodeInput {
  readonly code: string;
  readonly deviceId: string;
  readonly userId: string;
  readonly now?: Date;
}

/**
 * Atomic claim.
 *
 * - Happy path: `UPDATE ... WHERE code_hash = $1 AND device_id = $2 AND
 *   claimed_at IS NULL AND expires_at > $now RETURNING ...` flips the
 *   row to claimed and returns the endpoint in a single round-trip. A
 *   concurrent duplicate hitting the same predicate sees zero rows (the
 *   first claim already flipped `claimed_at`) and falls through.
 * - Zero-row path: a classifying `SELECT` on `code_hash` alone teases
 *   apart the three "same hash exists" causes (expired, already claimed,
 *   device-id mismatch) from the fourth (unknown code). Device-id
 *   mismatch collapses to `not_found` at the return site so a scanner
 *   cannot fingerprint which opaque codes exist in the ledger.
 *
 * Ordering of the zero-row branches:
 *
 *   device-id-mismatch → not_found (no leak)
 *   expired → expired (honest: the user's QR is stale)
 *   otherwise-claimed → already_used (honest: ditto)
 *   row absent → not_found
 *
 * Expiry is checked strictly (`expires_at > now`) — a row expiring at
 * exactly `now` is stale. Keeps the boundary on the conservative side,
 * same convention as `magic-link-attestation.ts`.
 */
export const exchangePairingCode = async (
  input: ExchangePairingCodeInput,
): Promise<ExchangeOutcome> => {
  const codeError = validatePairingCode(input.code);
  if (codeError !== null) {
    return { kind: 'not_found' };
  }
  const deviceError = validateDeviceId(input.deviceId);
  if (deviceError !== null) {
    return { kind: 'not_found' };
  }
  const now = input.now ?? new Date();
  const codeHash = hashPairingCode(input.code);

  const claimed = await db
    .update(devicePairingCode)
    .set({ claimedAt: now, claimedByUserId: input.userId })
    .where(
      and(
        eq(devicePairingCode.codeHash, codeHash),
        eq(devicePairingCode.deviceId, input.deviceId),
        isNull(devicePairingCode.claimedAt),
        sql`${devicePairingCode.expiresAt} > ${now}`,
      ),
    )
    .returning({
      deviceId: devicePairingCode.deviceId,
      deviceName: devicePairingCode.deviceName,
      tailscaleHost: devicePairingCode.tailscaleHost,
      tailscalePort: devicePairingCode.tailscalePort,
    });

  const claimedRow = claimed[0];
  if (claimedRow !== undefined) {
    return {
      kind: 'ok',
      device: {
        deviceId: claimedRow.deviceId,
        deviceName: claimedRow.deviceName,
        host: claimedRow.tailscaleHost,
        port: claimedRow.tailscalePort,
      },
    };
  }

  const existing = await db
    .select({
      deviceId: devicePairingCode.deviceId,
      expiresAt: devicePairingCode.expiresAt,
      claimedAt: devicePairingCode.claimedAt,
    })
    .from(devicePairingCode)
    .where(eq(devicePairingCode.codeHash, codeHash))
    .limit(1);
  const row = existing[0];
  if (row === undefined) {
    return { kind: 'not_found' };
  }
  if (row.deviceId !== input.deviceId) {
    return { kind: 'not_found' };
  }
  if (row.claimedAt !== null) {
    return { kind: 'already_used' };
  }
  if (row.expiresAt.getTime() <= now.getTime()) {
    return { kind: 'expired' };
  }
  // Should be unreachable: the UPDATE predicate matches exactly the
  // complement of the three branches above. Treat a spurious fall-
  // through as a not-found — safer than leaking internal state if the
  // predicate and the classifier ever drift.
  return { kind: 'not_found' };
};
