import { createHash, randomUUID } from 'node:crypto';
import { isIP } from 'node:net';
import { and, eq, isNull, lt, ne, sql } from 'drizzle-orm';
import { devicePairingCode } from '~/db/schema.ts';
import { db } from '~/lib/db.ts';
import { loadSessionSpki, publishPairGrant } from '~/lib/device-acl.ts';

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
 * Tailscale-only host validator for `tailscale_host`.
 *
 * The app opens a plaintext TCP channel to this address. Without this
 * constraint a compromised issuance pipeline (or an attacker who landed
 * write access to the provisioning surface) could direct every paired
 * app to an arbitrary public host; the app-to-device TCP wire carries
 * control commands and receives `StreamOffer` payloads whose LiveKit
 * URL is dialed unconditionally, so redirection compounds into
 * credential exfiltration (see `LiveStreamCredentials` wss-only gate).
 * Pinning the endpoint to tailnet-only addresses collapses that
 * attack surface: the attacker would need to be a tailnet peer of the
 * victim, a dramatically higher bar than "controls any DNS name."
 *
 * Accepted shapes:
 *
 * - **IPv4** inside the Tailscale CGNAT range `100.64.0.0/10`. Tailscale
 *   assigns every node an address in this block; no other global IPv4
 *   range is reachable via WireGuard-only transport.
 * - **IPv6** inside `fd7a:115c:a1e0::/48`, the Tailscale ULA allocation.
 *   Zone identifiers (`%eth0`) are rejected — tailnet addresses are
 *   globally routable within the tailnet and never require a scope id.
 * - **MagicDNS hostnames** under `.ts.net` (current Tailscale MagicDNS
 *   suffix) or `.tailscale.net` (legacy, still emitted by some
 *   tailnets). Must carry at least one non-empty label to the left of
 *   the suffix and otherwise satisfy RFC 1035 label rules.
 *
 * Rejected: every other DNS name, every other IP literal, URL syntax
 * (scheme, path, port, userinfo), whitespace, non-ASCII, bare suffixes
 * (`.ts.net` alone), and IPv6 addresses outside the Tailscale block.
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

/**
 * Public DNS suffixes Tailscale emits for MagicDNS names. `.ts.net` is
 * the current production suffix; `.tailscale.net` is retained for older
 * tailnets that still resolve under the legacy zone. Anything else is
 * not a tailnet hostname and must be rejected.
 */
export const TAILSCALE_MAGIC_DNS_SUFFIXES: readonly string[] = ['.ts.net', '.tailscale.net'];

const isAsciiDigit = (code: number): boolean => code >= 0x30 && code <= 0x39;
const isAsciiAlpha = (code: number): boolean =>
  (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);

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

const stripIpv6Brackets = (candidate: string): string =>
  candidate.startsWith('[') && candidate.endsWith(']') ? candidate.slice(1, -1) : candidate;

const isDnsName = (candidate: string): boolean => {
  const labels = candidate.split('.');
  if (labels.length === 0 || labels.some((label) => label.length === 0)) {
    return false;
  }
  return labels.every((label) => isDnsLabel(label));
};

/**
 * True iff `candidate` is a valid IPv4 dotted quad inside
 * `100.64.0.0/10` — the Tailscale CGNAT allocation. `isIP` vets the
 * byte-level parse (rejecting leading zeros, out-of-range octets, and
 * non-decimal shapes); the range check is the only Tailscale-specific
 * gate.
 */
const isTailscaleCGNAT4 = (candidate: string): boolean => {
  if (isIP(candidate) !== 4) {
    return false;
  }
  const parts = candidate.split('.');
  if (parts.length !== 4) {
    return false;
  }
  const [first, second] = parts;
  if (first === undefined || second === undefined) {
    return false;
  }
  const a = Number(first);
  const b = Number(second);
  if (!Number.isInteger(a) || !Number.isInteger(b)) {
    return false;
  }
  // 100.64.0.0/10: first octet must be 100, second octet must be in
  // [64, 127] (the /10 puts the next 2 bits under the mask).
  return a === 100 && b >= 64 && b <= 127;
};

/**
 * Return the first three fully-expanded 16-bit groups of a well-formed
 * IPv6 literal (already vetted by `isIP`), e.g. `"fd7a:115c:a1e0"` for
 * `fd7a:115c:a1e0:ab12::1`. Handles RFC 5952 `::` compression.
 * Returns `null` on any parse failure so callers can fail closed.
 */
/**
 * Parse an IPv6 literal into an 8-group normalized array. Returns
 * null if the literal is malformed (uses more than one `::`, has
 * too many explicit groups, etc.). Split out of `ipv6Prefix48` so
 * each helper stays below the complexity ceiling.
 */
const splitIpv6Half = (half: string | undefined): string[] =>
  half === undefined || half === '' ? [] : half.split(':');

const parseIpv6Groups = (lower: string): readonly string[] | null => {
  const halves = lower.split('::');
  if (halves.length > 2) {
    return null;
  }
  const hasCompression = halves.length === 2;
  const head = splitIpv6Half(halves[0]);
  const tail = hasCompression ? splitIpv6Half(halves[1]) : [];
  if (!hasCompression) {
    return head.length === 8 ? head : null;
  }
  const zerosNeeded = 8 - head.length - tail.length;
  if (zerosNeeded < 0) {
    return null;
  }
  return [...head, ...Array.from({ length: zerosNeeded }, () => '0'), ...tail];
};

const ipv6Prefix48 = (v6: string): string | null => {
  const groups = parseIpv6Groups(v6.toLowerCase());
  if (groups === null) {
    return null;
  }
  const prefix = groups.slice(0, 3);
  for (const g of prefix) {
    if (g.length === 0 || g.length > 4) {
      return null;
    }
  }
  return prefix.map((g) => g.padStart(4, '0')).join(':');
};

/**
 * True iff `candidate` is an IPv6 literal inside `fd7a:115c:a1e0::/48`
 * — the Tailscale ULA block. Rejects zone identifiers (`fe80::1%eth0`
 * style): tailnet addresses do not need a scope id, and accepting one
 * would open a link-local smuggling path. `isIP` handles the byte-level
 * parse; the prefix check is the only Tailscale-specific gate.
 */
const isTailscaleCGNAT6 = (candidate: string): boolean => {
  if (candidate.includes('%')) {
    return false;
  }
  if (isIP(candidate) !== 6) {
    return false;
  }
  const prefix = ipv6Prefix48(candidate);
  if (prefix === null) {
    return false;
  }
  return prefix === 'fd7a:115c:a1e0';
};

/**
 * True iff `candidate` is a DNS name ending in a Tailscale MagicDNS
 * suffix with at least one non-empty label to the left.
 *
 * A bare suffix (`".ts.net"`, `"ts.net"`) is not a hostname and the
 * app would be unable to dial it, so the validator refuses it at
 * issuance rather than letting a malformed row survive.
 */
const isTailscaleMagicDNS = (candidate: string): boolean => {
  const lower = candidate.toLowerCase();
  for (const suffix of TAILSCALE_MAGIC_DNS_SUFFIXES) {
    if (!lower.endsWith(suffix)) {
      continue;
    }
    const head = lower.slice(0, -suffix.length);
    if (head.length === 0) {
      return false;
    }
    // `head` must itself be a valid DNS name (one or more labels, each
    // RFC 1035 conformant). A leading dot (`.host.ts.net` → head
    // `"."`) is caught here because `isDnsName` requires no empty
    // labels.
    return isDnsName(head);
  }
  return false;
};

export const isPlausibleTailscaleHost = (candidate: string): boolean => {
  if (candidate.length === 0 || candidate.length > MAX_TAILSCALE_HOST_LENGTH) {
    return false;
  }
  const inner = stripIpv6Brackets(candidate);
  if (inner.length === 0) {
    return false;
  }
  // IPv6 parse first (colons are disjoint from IPv4 / DNS names). Then
  // IPv4 CGNAT. Then MagicDNS by suffix. The order does not matter for
  // correctness because the three predicates are mutually exclusive on
  // well-formed inputs, but fast-path the IP cases since CGNAT is the
  // common shape.
  if (inner.includes(':')) {
    return isTailscaleCGNAT6(inner);
  }
  if (isIP(inner) === 4) {
    return isTailscaleCGNAT4(inner);
  }
  return isTailscaleMagicDNS(inner);
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
    throw new PairingCodeIssueError(
      'tailscaleHost',
      'must be a Tailscale address: CGNAT IPv4 (100.64.0.0/10), Tailscale IPv6 (fd7a:115c:a1e0::/48), or a MagicDNS hostname under .ts.net / .tailscale.net',
    );
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
  /**
   * Claiming session's id. The device ACL write writes a grant
   * under the SPKI stored on `session_attestation` for this
   * session, which means a caller can only publish an ACL for a
   * device they themselves authenticate to — bearer + SE key, both
   * already proven by the protected-route gate wrapping this
   * exchange.
   */
  readonly sessionId: string;
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
interface ClaimTransactionInput {
  readonly codeHash: string;
  readonly deviceId: string;
  readonly userId: string;
  readonly sessionSpki: string;
  readonly now: Date;
}

interface ClaimedRow {
  readonly id: string;
  readonly deviceId: string;
  readonly deviceName: string | null;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
}

/**
 * Transaction body for the atomic pair-claim. Isolated in its own
 * function so `exchangePairingCode` stays simple and this function
 * has a single, unambiguous pair of return paths (the matched-claim
 * row, or null when the update matched nothing).
 */
const runClaimTransaction = async (
  tx: Parameters<Parameters<typeof db.transaction>[0]>[0],
  input: ClaimTransactionInput,
): Promise<ClaimedRow | null> => {
  // Atomic claim: flip `claimed_at` + `claimed_by_user_id` on a
  // row whose code/device/non-claimed/non-expired predicate
  // matches. Zero rows → fall through to the classifying SELECT in
  // the caller.
  const claimedRows = await tx
    .update(devicePairingCode)
    .set({ claimedAt: input.now, claimedByUserId: input.userId })
    .where(
      and(
        eq(devicePairingCode.codeHash, input.codeHash),
        eq(devicePairingCode.deviceId, input.deviceId),
        isNull(devicePairingCode.claimedAt),
        sql`${devicePairingCode.expiresAt} > ${input.now}`,
      ),
    )
    .returning({
      id: devicePairingCode.id,
      deviceId: devicePairingCode.deviceId,
      deviceName: devicePairingCode.deviceName,
      tailscaleHost: devicePairingCode.tailscaleHost,
      tailscalePort: devicePairingCode.tailscalePort,
    });
  const row = claimedRows[0];
  if (row === undefined) {
    return null;
  }
  // Revoke every prior active claim for the same device_id. This is
  // the invariant that makes `GET /api/v1/devices/paired` honest:
  // at any moment there is at most one non-revoked active claim per
  // device_id. A re-pair (same device, any user) supersedes the
  // previous owner cleanly. `row.id` is excluded so the freshly-
  // claimed row stays active.
  await tx
    .update(devicePairingCode)
    .set({ revokedAt: input.now })
    .where(
      and(
        eq(devicePairingCode.deviceId, input.deviceId),
        sql`${devicePairingCode.claimedAt} IS NOT NULL`,
        isNull(devicePairingCode.revokedAt),
        ne(devicePairingCode.id, row.id),
      ),
    );
  // Publish the ACL grant under this session's SPKI. The helper
  // revokes any competing active grants for the same device slug
  // and bumps the per-slug revision counter — all in the same
  // transaction so the pair claim and the ACL change succeed or
  // fail together.
  await publishPairGrant(tx, {
    deviceSlug: input.deviceId,
    userSpkiB64: input.sessionSpki,
    userId: input.userId,
    now: input.now,
  });
  return row;
};

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

  // The claim path looks up the claiming session's SPKI OUTSIDE the
  // pair-claim transaction. `session_attestation` is immutable for
  // the session's lifetime (written atomically at sign-in) so
  // reading it outside the transaction does not race with anything
  // the pair claim depends on. Keeping the SPKI lookup out of the
  // transaction lets us fail fast (before the UPDATE) if the row is
  // missing; a concurrent sign-out would only drop the session and
  // the bearer check above already rejects that case.
  const sessionSpki = await loadSessionSpki(input.sessionId);
  if (sessionSpki === null) {
    // Should be unreachable for a caller past the protected-route
    // gate: the gate requires an attested session, and sign-in
    // writes session_attestation atomically. Surface as not_found
    // rather than leaking a distinct internal-state signal.
    return { kind: 'not_found' };
  }

  const claimed = await db.transaction(
    async (tx) =>
      await runClaimTransaction(tx, {
        codeHash,
        deviceId: input.deviceId,
        userId: input.userId,
        sessionSpki,
        now,
      }),
  );

  if (claimed !== null) {
    return {
      kind: 'ok',
      device: {
        deviceId: claimed.deviceId,
        deviceName: claimed.deviceName,
        host: claimed.tailscaleHost,
        port: claimed.tailscalePort,
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

/**
 * One active pairing surfaced by `listPairedDevicesForUser`. Mirrors
 * the wire shape returned by `GET /api/v1/devices/paired`. `pairedAt`
 * is the claim timestamp so the app can show "paired 3 days ago" and
 * sort multiple devices deterministically.
 */
export interface ActivePairedDevice {
  readonly deviceId: string;
  readonly deviceName: string | null;
  readonly host: string;
  readonly port: number;
  readonly pairedAt: Date;
}

/**
 * Return the current non-revoked active claims owned by `userId`,
 * ordered by most-recent claim first.
 *
 * "Active" = `claimed_at IS NOT NULL AND revoked_at IS NULL`. A row
 * that was once claimed and later superseded by a re-pair has
 * `revoked_at` set and is excluded. A row whose user was deleted has
 * `claimed_by_user_id` NULL-ed via the FK cascade and is excluded
 * here by the `eq(claimedByUserId, userId)` predicate.
 *
 * Used by the iOS app's launch-time / daily ownership-re-check: the
 * app compares its Keychain-cached `device_id` against this list, and
 * treats a miss as "another user pairs this device now" → wipe
 * endpoint + force re-pair.
 */
export const listPairedDevicesForUser = async (
  userId: string,
): Promise<readonly ActivePairedDevice[]> => {
  const rows = await db
    .select({
      deviceId: devicePairingCode.deviceId,
      deviceName: devicePairingCode.deviceName,
      tailscaleHost: devicePairingCode.tailscaleHost,
      tailscalePort: devicePairingCode.tailscalePort,
      claimedAt: devicePairingCode.claimedAt,
    })
    .from(devicePairingCode)
    .where(
      and(
        eq(devicePairingCode.claimedByUserId, userId),
        sql`${devicePairingCode.claimedAt} IS NOT NULL`,
        isNull(devicePairingCode.revokedAt),
      ),
    )
    .orderBy(sql`${devicePairingCode.claimedAt} DESC`);
  return rows.map(
    (row): ActivePairedDevice => ({
      deviceId: row.deviceId,
      deviceName: row.deviceName,
      host: row.tailscaleHost,
      port: row.tailscalePort,
      // `claimed_at` is non-null because the SQL predicate guarantees
      // it. Drizzle's typed projection keeps it `Date | null`, so we
      // assert here rather than threading a narrowed type out of the
      // query.
      pairedAt: row.claimedAt ?? new Date(0),
    }),
  );
};
