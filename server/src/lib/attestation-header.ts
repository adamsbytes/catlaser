import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import { decodeAttestationBinding } from '~/lib/attestation-binding.ts';

/**
 * Server-side parser for the `x-device-attestation` header emitted by the
 * iOS (and, when shipped, Android) client. Mirrors the iOS
 * `DeviceAttestationEncoder.decodeHeaderValue` contract.
 *
 * Wire format:
 *
 * ```
 * base64(UTF-8(JSON({
 *   "bnd": "<binding wire value>",
 *   "fph": "<base64url-no-pad(sha256(canonical fingerprint JSON), 32 bytes)>",
 *   "pk":  "<base64(DER SubjectPublicKeyInfo of the client's P-256 public key)>",
 *   "sig": "<base64(DER ECDSA-P256-SHA256 signature over fph_raw || bnd_utf8)>",
 *   "v":   4
 * })))
 * ```
 *
 * This parser does NOT verify the ECDSA signature, nor does it verify that
 * `pk` carries the exact 26-byte P-256 SPKI prefix. Those checks belong to
 * the attestation-binding-enforcement stage in `attestation-verify.ts`
 * (see ADR-006). What this parser does guarantee:
 *
 * - Header value ≤ `MAX_HEADER_VALUE_BYTES` (matches iOS cap — catches
 *   runaway encoding bugs before they hit the database).
 * - Outer value is valid standard base64.
 * - Inner payload is a JSON object with exactly the five required keys, each
 *   of the expected type.
 * - `v === 4`.
 * - `fph` decodes via base64url-no-pad to exactly 32 bytes (SHA-256 digest).
 * - `pk` decodes via standard base64 to a non-empty byte sequence.
 * - `sig` decodes via standard base64 to a non-empty byte sequence.
 * - `bnd` parses via `decodeAttestationBinding`.
 */

/**
 * Upper bound on the serialized header value. Empirically ~450-500 bytes
 * for v3 (32-byte hash + 91-byte SPKI + ~72-byte signature + JSON framing
 * including `bnd`, everything base64'd on the outside). HTTP stacks typically
 * cap header values at 8 KiB; this conservative ceiling catches a runaway
 * encoding bug long before the transport layer would notice.
 */
export const MAX_HEADER_VALUE_BYTES = 2048;

/**
 * Current wire-format version. Clients at `v != 4` are rejected outright.
 *
 * Version history:
 *
 * - v4 (current) — adds a signed timestamp to the `sis:` binding, rendered as
 *   `sis:<unix_seconds>:<raw_nonce>`. The attestation plugin enforces the same
 *   ±60s skew window on `sis:` that it does on `req:`/`out:`/`api:`, closing
 *   the capture-then-replay vector the v3 nonce-only format left open (an
 *   attacker who captured a complete v3 `(body, attestation)` pair could
 *   replay it for the full Apple/Google ID-token lifetime — roughly 10
 *   minutes for Apple, up to an hour for Google).
 * - v3 — introduced per-binding tagged freshness; `sis:` carried the raw
 *   nonce only (no timestamp). Retired with v4.
 * - v2, v1 — pre-attestation wire formats. Permanently retired.
 */
export const ATTESTATION_VERSION = 4;

/** SHA-256 digests are exactly 32 bytes. Hard-enforced. */
export const FINGERPRINT_HASH_BYTES = 32;

/**
 * Minimum accepted length for the serialized SPKI. A proper P-256
 * SubjectPublicKeyInfo is 91 bytes; we enforce only the prefix-length lower
 * bound here (26 bytes) because byte-for-byte SPKI validation is part of the
 * signature-verify stage, not this parser. Everything larger still has to be
 * a well-formed SPKI to survive the cryptographic check later.
 */
export const MIN_PUBLIC_KEY_BYTES = 26;

export interface ParsedAttestation {
  readonly version: number;
  readonly fingerprintHash: Uint8Array;
  readonly publicKeySPKI: Uint8Array;
  readonly binding: AttestationBinding;
  readonly signature: Uint8Array;
}

export type AttestationHeaderParseCode =
  | 'ATTESTATION_HEADER_EMPTY'
  | 'ATTESTATION_HEADER_TOO_LARGE'
  | 'ATTESTATION_OUTER_BASE64'
  | 'ATTESTATION_PAYLOAD_JSON'
  | 'ATTESTATION_PAYLOAD_SHAPE'
  | 'ATTESTATION_VERSION_MISMATCH'
  | 'ATTESTATION_FPH_INVALID'
  | 'ATTESTATION_PK_INVALID'
  | 'ATTESTATION_SIG_INVALID';

export class AttestationHeaderParseError extends Error {
  public readonly code: AttestationHeaderParseCode;

  public constructor(code: AttestationHeaderParseCode, message: string) {
    super(message);
    this.name = 'AttestationHeaderParseError';
    this.code = code;
  }
}

interface WirePayload {
  readonly bnd: string;
  readonly fph: string;
  readonly pk: string;
  readonly sig: string;
  readonly v: number;
}

const REQUIRED_KEYS: ReadonlySet<string> = new Set(['bnd', 'fph', 'pk', 'sig', 'v']);
const STANDARD_BASE64_PATTERN = /^[+\/0-9A-Za-z]*={0,2}$/v;
const BASE64URL_PATTERN = /^[\w\-]*$/v;

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

const determinePadCount = (input: string): 0 | 1 | 2 => {
  if (input.endsWith('==')) {
    return 2;
  }
  if (input.endsWith('=')) {
    return 1;
  }
  return 0;
};

const decodeStandardBase64 = (
  input: string,
  errorCode: AttestationHeaderParseCode,
  label: string,
): Uint8Array => {
  if (input.length === 0) {
    throw new AttestationHeaderParseError(errorCode, `${label} is empty`);
  }
  if (input.length % 4 !== 0) {
    throw new AttestationHeaderParseError(
      errorCode,
      `${label} is not a valid base64 length (got ${input.length.toString()})`,
    );
  }
  if (!STANDARD_BASE64_PATTERN.test(input)) {
    throw new AttestationHeaderParseError(
      errorCode,
      `${label} contains characters outside the standard base64 alphabet`,
    );
  }
  const padCount = determinePadCount(input);
  if (padCount > 0 && input.indexOf('=') !== input.length - padCount) {
    throw new AttestationHeaderParseError(errorCode, `${label} has misplaced padding`);
  }
  return Uint8Array.from(Buffer.from(input, 'base64'));
};

const decodeBase64UrlNoPad = (
  input: string,
  errorCode: AttestationHeaderParseCode,
  label: string,
): Uint8Array => {
  if (input.length === 0) {
    throw new AttestationHeaderParseError(errorCode, `${label} is empty`);
  }
  if (!BASE64URL_PATTERN.test(input)) {
    throw new AttestationHeaderParseError(
      errorCode,
      `${label} contains characters outside the base64url alphabet`,
    );
  }
  const remainder = input.length % 4;
  if (remainder === 1) {
    throw new AttestationHeaderParseError(
      errorCode,
      `${label} is not a valid base64url length (got ${input.length.toString()})`,
    );
  }
  const padded = remainder === 0 ? input : input + '='.repeat(4 - remainder);
  const standard = padded.replaceAll('-', '+').replaceAll('_', '/');
  return Uint8Array.from(Buffer.from(standard, 'base64'));
};

const decodeUtf8 = (
  bytes: Uint8Array,
  errorCode: AttestationHeaderParseCode,
  label: string,
): string => {
  try {
    return utf8Decoder.decode(bytes);
  } catch (error) {
    throw new AttestationHeaderParseError(
      errorCode,
      `${label} is not valid UTF-8: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
};

const encodeStandardBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64');

const encodeBase64UrlNoPad = (bytes: Uint8Array): string =>
  encodeStandardBase64(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

const bindingWireValue = (binding: AttestationBinding): string => {
  switch (binding.tag) {
    case 'request':
      return `req:${binding.timestamp.toString()}`;
    case 'verify':
      return `ver:${binding.token}`;
    case 'social':
      return `sis:${binding.timestamp.toString()}:${binding.rawNonce}`;
    case 'signOut':
      return `out:${binding.timestamp.toString()}`;
    case 'api':
      return `api:${binding.timestamp.toString()}`;
    case 'deleteAccount':
      return `del:${binding.timestamp.toString()}`;
    default: {
      // switch-exhaustiveness-check ensures every union arm is handled; an
      // unreachable default covers future-arm typos inside the factory.
      const exhaustive: never = binding;
      throw new Error(`unreachable AttestationBinding tag: ${JSON.stringify(exhaustive)}`);
    }
  }
};

const assertRequiredKeys = (record: Record<string, unknown>): void => {
  for (const key of Object.keys(record)) {
    if (!REQUIRED_KEYS.has(key)) {
      throw new AttestationHeaderParseError(
        'ATTESTATION_PAYLOAD_SHAPE',
        `attestation payload has unexpected key '${key}'`,
      );
    }
  }
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const assertWirePayload = (value: unknown): WirePayload => {
  if (!isRecord(value)) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_PAYLOAD_SHAPE',
      'attestation payload is not a JSON object',
    );
  }
  assertRequiredKeys(value);
  const { bnd, fph, pk, sig, v } = value;
  if (typeof bnd !== 'string') {
    throw new AttestationHeaderParseError('ATTESTATION_PAYLOAD_SHAPE', 'bnd must be a string');
  }
  if (typeof fph !== 'string') {
    throw new AttestationHeaderParseError('ATTESTATION_PAYLOAD_SHAPE', 'fph must be a string');
  }
  if (typeof pk !== 'string') {
    throw new AttestationHeaderParseError('ATTESTATION_PAYLOAD_SHAPE', 'pk must be a string');
  }
  if (typeof sig !== 'string') {
    throw new AttestationHeaderParseError('ATTESTATION_PAYLOAD_SHAPE', 'sig must be a string');
  }
  if (typeof v !== 'number' || !Number.isInteger(v)) {
    throw new AttestationHeaderParseError('ATTESTATION_PAYLOAD_SHAPE', 'v must be an integer');
  }
  return { bnd, fph, pk, sig, v };
};

const parseAsJson = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_PAYLOAD_JSON',
      `attestation JSON parse failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
};

/**
 * Decode a raw `x-device-attestation` header value. Throws
 * `AttestationHeaderParseError` or `AttestationParseError` (for `bnd` payload
 * failures) on any deviation from the wire format.
 */
export const decodeAttestationHeader = (headerValue: string): ParsedAttestation => {
  if (headerValue.length === 0) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_HEADER_EMPTY',
      'x-device-attestation header is empty',
    );
  }
  if (headerValue.length > MAX_HEADER_VALUE_BYTES) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_HEADER_TOO_LARGE',
      `attestation header exceeds ${MAX_HEADER_VALUE_BYTES.toString()} bytes (got ${headerValue.length.toString()})`,
    );
  }

  const outer = decodeStandardBase64(
    headerValue,
    'ATTESTATION_OUTER_BASE64',
    'outer attestation payload',
  );
  const text = decodeUtf8(outer, 'ATTESTATION_PAYLOAD_JSON', 'outer attestation payload');
  const payload = assertWirePayload(parseAsJson(text));

  if (payload.v !== ATTESTATION_VERSION) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_VERSION_MISMATCH',
      `attestation version mismatch: expected ${ATTESTATION_VERSION.toString()}, got ${String(payload.v)}`,
    );
  }

  const fingerprintHash = decodeBase64UrlNoPad(payload.fph, 'ATTESTATION_FPH_INVALID', 'fph');
  if (fingerprintHash.length !== FINGERPRINT_HASH_BYTES) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_FPH_INVALID',
      `fph must be ${FINGERPRINT_HASH_BYTES.toString()} bytes, got ${fingerprintHash.length.toString()}`,
    );
  }

  const publicKeySPKI = decodeStandardBase64(payload.pk, 'ATTESTATION_PK_INVALID', 'pk');
  if (publicKeySPKI.length < MIN_PUBLIC_KEY_BYTES) {
    throw new AttestationHeaderParseError(
      'ATTESTATION_PK_INVALID',
      `pk must be at least ${MIN_PUBLIC_KEY_BYTES.toString()} bytes, got ${publicKeySPKI.length.toString()}`,
    );
  }

  const signature = decodeStandardBase64(payload.sig, 'ATTESTATION_SIG_INVALID', 'sig');
  if (signature.length === 0) {
    throw new AttestationHeaderParseError('ATTESTATION_SIG_INVALID', 'sig decoded to zero bytes');
  }

  const binding = decodeAttestationBinding(payload.bnd);

  return {
    version: payload.v,
    fingerprintHash,
    publicKeySPKI,
    binding,
    signature,
  };
};

/**
 * Encode a parsed attestation back to its wire format. Mirrors the iOS
 * `DeviceAttestationEncoder.encodeHeaderValue` byte-for-byte so that server
 * round-trip tests and future Swift→TS parity tests can share vectors. The
 * production server never encodes; only tests and offline tooling do.
 */
export const encodeAttestationHeader = (parsed: ParsedAttestation): string => {
  const payload: WirePayload = {
    bnd: bindingWireValue(parsed.binding),
    fph: encodeBase64UrlNoPad(parsed.fingerprintHash),
    pk: encodeStandardBase64(parsed.publicKeySPKI),
    sig: encodeStandardBase64(parsed.signature),
    v: parsed.version,
  };
  // Canonical key order (lexicographic) matches iOS `JSONEncoder.sortedKeys`.
  const canonical = `{"bnd":${JSON.stringify(payload.bnd)},"fph":${JSON.stringify(payload.fph)},"pk":${JSON.stringify(payload.pk)},"sig":${JSON.stringify(payload.sig)},"v":${payload.v.toString()}}`;
  return encodeStandardBase64(utf8Encoder.encode(canonical));
};
