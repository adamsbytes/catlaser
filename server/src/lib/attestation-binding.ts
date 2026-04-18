/**
 * Server-side port of the iOS `AttestationBinding` wire format.
 *
 * `bnd` is the per-call freshness input mixed into the ECDSA signature of a
 * `DeviceAttestation`. It renders on the wire as one of five tagged UTF-8
 * strings, distinguished by their first four characters:
 *
 * - `req:<unix_seconds>` — outbound magic-link request. Timestamp-skewed.
 * - `ver:<magic_link_token>` — magic-link verify. Bound to the server-issued token.
 * - `sis:<unix_seconds>:<raw_nonce>` — social ID-token exchange. Timestamp-skewed,
 *   AND bound to the per-sign-in nonce which is also echoed into the provider's
 *   ID token (verbatim for Google, hashed for Apple) and into the request body's
 *   `idToken.nonce` field for a three-way match. The timestamp pins the replay
 *   window to ±60s — a captured `(body, attestation)` pair cannot be resubmitted
 *   once the window elapses, closing the capture-then-replay vector the v3
 *   nonce-only binding left open (the ID-token `exp` alone was ~10 minutes wide).
 * - `out:<unix_seconds>` — sign-out. Same timestamp/skew contract as `req:`,
 *   distinct tag prevents a captured `req:` header from being replayed against
 *   sign-out (and vice versa).
 * - `api:<unix_seconds>` — every authenticated API call after sign-in. Same
 *   timestamp/skew contract as `req:`, `sis:`, and `out:`; distinct tag prevents a
 *   captured sign-in-time attestation from being replayed against a protected
 *   route, and vice versa. The protected-route middleware consumes this
 *   binding; the parser, encoder, and skew semantics stay shared across all
 *   five bindings so the crypto floor is consistent.
 *
 * The tagged prefix also prevents cross-context confusion: a caller that
 * stripped the prefix before signing/verifying would still see the raw signed
 * bytes differ in their first four characters between contexts.
 */

/**
 * Upper bound on the UTF-8 size of the wire value. Magic-link tokens and raw
 * nonces are small (tens of bytes); this bound exists so a malformed client
 * cannot inflate the attestation header. Enforced here at parse time and
 * mirrored on the iOS encode side.
 */
export const MAX_BND_WIRE_BYTES = 1024;

export type AttestationBinding =
  | { readonly tag: 'request'; readonly timestamp: bigint }
  | { readonly tag: 'verify'; readonly token: string }
  | { readonly tag: 'social'; readonly timestamp: bigint; readonly rawNonce: string }
  | { readonly tag: 'signOut'; readonly timestamp: bigint }
  | { readonly tag: 'api'; readonly timestamp: bigint };

export type AttestationBindingTag = AttestationBinding['tag'];

export type AttestationParseCode =
  | 'ATTESTATION_BND_TOO_LARGE'
  | 'ATTESTATION_BND_UNKNOWN_TAG'
  | 'ATTESTATION_BND_BAD_TIMESTAMP'
  | 'ATTESTATION_BND_EMPTY_TOKEN'
  | 'ATTESTATION_BND_CONTROL_CHARS';

export class AttestationParseError extends Error {
  public readonly code: AttestationParseCode;

  public constructor(code: AttestationParseCode, message: string) {
    super(message);
    this.name = 'AttestationParseError';
    this.code = code;
  }
}

const TAG_REQUEST = 'req:';
const TAG_VERIFY = 'ver:';
const TAG_SOCIAL = 'sis:';
const TAG_SIGN_OUT = 'out:';
const TAG_API = 'api:';

const DECIMAL_PATTERN = /^(?:0|[1-9]\d*)$/v;
const INT64_MAX = 9_223_372_036_854_775_807n;
const INT64_MAX_DECIMAL_DIGITS = 19;

/**
 * Any Unicode whitespace character OR Unicode control/format character.
 * `\p{Cc}` covers C0 + DEL + C1; `\p{Cf}` covers formatting marks such as
 * ZWNBSP (U+FEFF) and the bidi overrides; `\p{White_Space}` covers ASCII
 * space, NBSP, line/paragraph separators, the ogham space mark, etc.
 * Unicode property escapes require the `v` flag. This mirrors iOS's
 * `CharacterSet.whitespacesAndNewlines.union(.controlCharacters)` set,
 * which itself spans Unicode General Categories Cc + Cf plus whitespace:
 * a string iOS would refuse to transmit must also be rejected here, and
 * vice versa.
 */
const DISALLOWED_PAYLOAD_CHAR = /[\p{Cc}\p{Cf}\p{White_Space}]/v;

const utf8Encoder = new TextEncoder();
const utf8ByteLength = (value: string): number => utf8Encoder.encode(value).length;

/** Numeric payload after `req:` / `out:`. Positive, decimal, no leading zeros. */
const parseTimestamp = (input: string): bigint => {
  if (input.length === 0) {
    throw new AttestationParseError('ATTESTATION_BND_BAD_TIMESTAMP', 'bnd timestamp is empty');
  }
  if (!DECIMAL_PATTERN.test(input)) {
    throw new AttestationParseError(
      'ATTESTATION_BND_BAD_TIMESTAMP',
      'bnd timestamp is not a positive decimal integer',
    );
  }
  // Length cap under 2^63-1's 19-digit ceiling avoids BigInt overflow noise;
  // anything beyond that is certainly bogus.
  if (input.length > INT64_MAX_DECIMAL_DIGITS) {
    throw new AttestationParseError(
      'ATTESTATION_BND_BAD_TIMESTAMP',
      `bnd timestamp exceeds Int64 decimal width (${INT64_MAX_DECIMAL_DIGITS.toString()} digits)`,
    );
  }
  const parsed = BigInt(input);
  if (parsed <= 0n || parsed > INT64_MAX) {
    throw new AttestationParseError(
      'ATTESTATION_BND_BAD_TIMESTAMP',
      `bnd timestamp is not in positive Int64 range (got ${parsed.toString()})`,
    );
  }
  return parsed;
};

const parseOpaqueToken = (input: string, kind: string): string => {
  if (input.length === 0) {
    throw new AttestationParseError('ATTESTATION_BND_EMPTY_TOKEN', `bnd ${kind} is empty`);
  }
  if (DISALLOWED_PAYLOAD_CHAR.test(input)) {
    throw new AttestationParseError(
      'ATTESTATION_BND_CONTROL_CHARS',
      `bnd ${kind} contains control or whitespace characters`,
    );
  }
  return input;
};

/**
 * Decode a `bnd` wire value into a strongly-typed binding.
 *
 * Tolerates nothing beyond the exact wire format. Unknown tags, empty
 * payloads, timestamps with leading zeros, signed timestamps, non-decimal
 * timestamps, timestamps ≤ 0, and control characters in tokens/nonces all
 * reject. Mirrors the iOS `AttestationBinding.decode` contract byte-for-byte.
 */
export const decodeAttestationBinding = (wireValue: string): AttestationBinding => {
  const byteLength = utf8ByteLength(wireValue);
  if (byteLength > MAX_BND_WIRE_BYTES) {
    throw new AttestationParseError(
      'ATTESTATION_BND_TOO_LARGE',
      `bnd exceeds ${MAX_BND_WIRE_BYTES.toString()} bytes (got ${byteLength.toString()})`,
    );
  }

  if (wireValue.startsWith(TAG_REQUEST)) {
    return { tag: 'request', timestamp: parseTimestamp(wireValue.slice(TAG_REQUEST.length)) };
  }
  if (wireValue.startsWith(TAG_VERIFY)) {
    return {
      tag: 'verify',
      token: parseOpaqueToken(wireValue.slice(TAG_VERIFY.length), 'verify token'),
    };
  }
  if (wireValue.startsWith(TAG_SOCIAL)) {
    // `sis:` carries two fields separated by a single colon:
    //   <timestamp>:<rawNonce>
    // The nonce is URL-safe base64 in practice (the iOS `NonceGenerator`
    // emits base64url-no-pad over 32 random bytes), which contains neither
    // control characters nor `:`. We split on the FIRST `:` — any trailing
    // colon in the remainder would then be caught by `parseOpaqueToken`'s
    // control-char + whitespace gate IF it were a control byte, but a
    // plain `:` is not a control char. The precise shape is therefore:
    // "[digits]:[non-empty nonce without whitespace/control]". An embedded
    // colon inside the nonce is rejected by the opaque-token gate only if
    // it is a control char; otherwise it is accepted as part of the
    // rawNonce verbatim — acceptable because the three-way nonce match
    // (attestation binding <-> body.idToken.nonce <-> provider ID-token
    // claim) is byte-exact and the other two legs carry the same bytes.
    const payload = wireValue.slice(TAG_SOCIAL.length);
    const separator = payload.indexOf(':');
    if (separator === -1) {
      throw new AttestationParseError(
        'ATTESTATION_BND_BAD_TIMESTAMP',
        "sis: binding is missing the ':<rawNonce>' suffix (expected 'sis:<unix_seconds>:<raw_nonce>')",
      );
    }
    const timestampText = payload.slice(0, separator);
    const rawNonce = payload.slice(separator + 1);
    return {
      tag: 'social',
      timestamp: parseTimestamp(timestampText),
      rawNonce: parseOpaqueToken(rawNonce, 'social raw nonce'),
    };
  }
  if (wireValue.startsWith(TAG_SIGN_OUT)) {
    return { tag: 'signOut', timestamp: parseTimestamp(wireValue.slice(TAG_SIGN_OUT.length)) };
  }
  if (wireValue.startsWith(TAG_API)) {
    return { tag: 'api', timestamp: parseTimestamp(wireValue.slice(TAG_API.length)) };
  }
  throw new AttestationParseError(
    'ATTESTATION_BND_UNKNOWN_TAG',
    `bnd has no recognised tag (expected '${TAG_REQUEST}', '${TAG_VERIFY}', '${TAG_SOCIAL}', '${TAG_SIGN_OUT}', or '${TAG_API}')`,
  );
};
