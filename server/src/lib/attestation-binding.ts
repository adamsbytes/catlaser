/**
 * Server-side port of the iOS `AttestationBinding` wire format.
 *
 * `bnd` is the per-call freshness input mixed into the ECDSA signature of a
 * `DeviceAttestation`. It renders on the wire as one of four tagged UTF-8
 * strings, distinguished by their first four characters:
 *
 * - `req:<unix_seconds>` — outbound magic-link request. Timestamp-skewed.
 * - `ver:<magic_link_token>` — magic-link verify. Bound to the server-issued token.
 * - `sis:<raw_nonce>` — social ID-token exchange. Bound to the per-sign-in nonce
 *   which is also echoed into the provider's ID token (verbatim for Google,
 *   hashed for Apple) and into the request body's `idToken.nonce` field for a
 *   three-way match.
 * - `out:<unix_seconds>` — sign-out. Same timestamp/skew contract as `req:`,
 *   distinct tag prevents a captured `req:` header from being replayed against
 *   sign-out (and vice versa).
 * - `api:<unix_seconds>` — every authenticated API call after sign-in. Same
 *   timestamp/skew contract as `req:` and `out:`; distinct tag prevents a
 *   captured sign-in-time attestation from being replayed against a protected
 *   route, and vice versa. Step 7 mounts this binding on the protected-route
 *   middleware; step 6 establishes the parser, encoder, and skew semantics so
 *   the crypto floor is consistent across all five bindings.
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
  | { readonly tag: 'social'; readonly rawNonce: string }
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
    return {
      tag: 'social',
      rawNonce: parseOpaqueToken(wireValue.slice(TAG_SOCIAL.length), 'social raw nonce'),
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
