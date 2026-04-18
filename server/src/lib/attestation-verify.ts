import { createPublicKey, timingSafeEqual, verify } from 'node:crypto';
import type { KeyObject } from 'node:crypto';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';

/**
 * Crypto primitives for v3 device attestation. Owns the two concerns that
 * BUILD.md Part 9 step 5 names alongside the header parser:
 *
 * 1. Byte-for-byte P-256 SubjectPublicKeyInfo validation. The 26-byte
 *    `EC_P256_SPKI_PREFIX` encodes `AlgorithmIdentifier { id-ecPublicKey,
 *    secp256r1 }` followed by the 65-byte uncompressed X9.63 point
 *    (`0x04 || X || Y`). A client forging any other EC curve — or any
 *    non-EC SPKI — is refused here before the signature verifier is
 *    ever invoked, so a curve-confusion or RSA-downgrade attack never
 *    reaches `crypto.verify`. These constants are byte-identical to
 *    iOS `DeviceIdentity.ecP256SPKIPrefix` so the two sides of the
 *    wire agree on what a valid public key looks like.
 *
 * 2. ECDSA-P256-SHA256 verification over `fph_raw || bnd_utf8`. The
 *    signed message is reconstructed from the parsed attestation and
 *    fed to `crypto.verify` with `dsaEncoding: 'der'` — iOS emits a
 *    DER-encoded ECDSA signature (via `P256.Signing.ECDSASignature.
 *    derRepresentation`), so the server accepts DER directly rather
 *    than converting to IEEE P1363.
 *
 * What this module deliberately does NOT do, kept here as a load-bearing
 * step-boundary note: no `req:` / `out:` skew enforcement (step 6), no
 * stored `fph` / `pk` byte-equal on `ver:` (step 6), no `api:` per-
 * request attestation (step 7), no idempotency-key replay defence
 * (step 8). The crypto floor is separable from those semantic checks so
 * later steps can layer on top without rewriting anything here.
 */

/**
 * DER-encoded `SubjectPublicKeyInfo` prefix for an EC P-256 public key.
 * 26 bytes, ending with the uncompressed-point tag (`0x00` is the final
 * byte of the BIT STRING length/header; the uncompressed-point indicator
 * `0x04` follows, then the 64 bytes of X || Y).
 *
 * Derivation: RFC 5480 §2.1.1.1 — `AlgorithmIdentifier` of
 * `ecPublicKey` (OID 1.2.840.10045.2.1) paired with curve parameters
 * `secp256r1` (OID 1.2.840.10045.3.1.7), wrapped in a 91-byte
 * `SubjectPublicKeyInfo`. Identical bytes to what `openssl ec -pubout
 * -outform DER` emits for any P-256 key.
 */
export const EC_P256_SPKI_PREFIX: Readonly<Uint8Array> = Uint8Array.from([
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
  0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]);

/** X9.63 uncompressed point tag. Every valid P-256 public key begins
 * its 65-byte point with this byte. Compressed points (`0x02`/`0x03`)
 * produce a different SPKI length and are rejected implicitly by the
 * 91-byte total-size check; the explicit tag check here is defence-
 * in-depth against a client that forged the prefix bytes verbatim. */
const UNCOMPRESSED_POINT_TAG = 0x04;

/** 65-byte uncompressed X9.63 point — the second half of a P-256 SPKI. */
export const EC_P256_X963_POINT_BYTES = 65;

/** Exact byte length of a well-formed P-256 SubjectPublicKeyInfo. */
export const EC_P256_SPKI_TOTAL_BYTES: number =
  EC_P256_SPKI_PREFIX.length + EC_P256_X963_POINT_BYTES;

export type AttestationVerifyCode = 'ATTESTATION_SPKI_INVALID' | 'ATTESTATION_SIGNATURE_INVALID';

export class AttestationVerifyError extends Error {
  public readonly code: AttestationVerifyCode;

  public constructor(code: AttestationVerifyCode, message: string) {
    super(message);
    this.name = 'AttestationVerifyError';
    this.code = code;
  }
}

/**
 * Constant-time byte comparison against the known P-256 SPKI prefix.
 * The SPKI prefix is not secret (it's a fixed ASN.1 constant published
 * in RFC 5480) so timing leakage here has no practical adversarial
 * value; using `timingSafeEqual` is idiomatic in this codebase and
 * sidesteps lint-level timing heuristics.
 */
const prefixMatches = (candidate: Uint8Array): boolean => {
  if (candidate.length !== EC_P256_SPKI_PREFIX.length) {
    return false;
  }
  return timingSafeEqual(candidate, EC_P256_SPKI_PREFIX);
};

/**
 * Assert that `spki` is a structurally well-formed P-256
 * `SubjectPublicKeyInfo`. Throws `AttestationVerifyError` with
 * `ATTESTATION_SPKI_INVALID` on any deviation. Does NOT validate the
 * curve-point equation (y² = x³ + ax + b) — that check happens inside
 * `crypto.createPublicKey`, which rejects points-at-infinity and
 * off-curve points with a thrown error that `verifyAttestationSignature`
 * translates into the same code. The structural check here fails fast
 * and with a specific message before the heavier OpenSSL parse runs.
 */
export const assertValidEcP256Spki = (spki: Uint8Array): void => {
  if (spki.length !== EC_P256_SPKI_TOTAL_BYTES) {
    throw new AttestationVerifyError(
      'ATTESTATION_SPKI_INVALID',
      `expected ${EC_P256_SPKI_TOTAL_BYTES.toString()}-byte P-256 SPKI, got ${spki.length.toString()}`,
    );
  }
  const prefix = spki.subarray(0, EC_P256_SPKI_PREFIX.length);
  if (!prefixMatches(prefix)) {
    throw new AttestationVerifyError(
      'ATTESTATION_SPKI_INVALID',
      'SPKI prefix does not match id-ecPublicKey + secp256r1',
    );
  }
  if (spki[EC_P256_SPKI_PREFIX.length] !== UNCOMPRESSED_POINT_TAG) {
    throw new AttestationVerifyError(
      'ATTESTATION_SPKI_INVALID',
      'EC public key point is not in uncompressed X9.63 form',
    );
  }
};

const utf8Encoder = new TextEncoder();

const bindingWireBytes = (parsed: ParsedAttestation): Uint8Array => {
  const { binding } = parsed;
  switch (binding.tag) {
    case 'request':
      return utf8Encoder.encode(`req:${binding.timestamp.toString()}`);
    case 'verify':
      return utf8Encoder.encode(`ver:${binding.token}`);
    case 'social':
      return utf8Encoder.encode(`sis:${binding.rawNonce}`);
    case 'signOut':
      return utf8Encoder.encode(`out:${binding.timestamp.toString()}`);
    case 'api':
      return utf8Encoder.encode(`api:${binding.timestamp.toString()}`);
    default: {
      const exhaustive: never = binding;
      throw new Error(`unreachable AttestationBinding tag: ${JSON.stringify(exhaustive)}`);
    }
  }
};

/**
 * Reconstruct the exact byte sequence iOS feeds into
 * `identity.sign(_:)` — the 32-byte fingerprint hash followed by the
 * canonical UTF-8 encoding of the binding (`req:<ts>`, `ver:<token>`,
 * `sis:<nonce>`, or `out:<ts>`). Exposed as its own function so
 * signature-verify tests and step-6 enforcement can share the same
 * byte-level view of the signed message.
 */
export const buildSignedMessage = (parsed: ParsedAttestation): Uint8Array => {
  const fph = parsed.fingerprintHash;
  const bnd = bindingWireBytes(parsed);
  const out = new Uint8Array(fph.length + bnd.length);
  out.set(fph, 0);
  out.set(bnd, fph.length);
  return out;
};

const importPublicKey = (spki: Uint8Array): KeyObject => {
  try {
    return createPublicKey({ key: Buffer.from(spki), format: 'der', type: 'spki' });
  } catch (error) {
    throw new AttestationVerifyError(
      'ATTESTATION_SPKI_INVALID',
      `public key import failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
};

/**
 * Verify the attestation's ECDSA signature. Throws
 * `AttestationVerifyError` with code `ATTESTATION_SPKI_INVALID` when
 * the SPKI is structurally bad or the point is off-curve, or
 * `ATTESTATION_SIGNATURE_INVALID` when the signature fails to verify.
 *
 * The signed message is exactly `fingerprintHash || bnd_utf8` — same
 * byte sequence iOS passes to `DeviceIdentityStoring.sign(_:)`. The
 * signature on the wire is DER-encoded; `dsaEncoding: 'der'` keeps
 * Node from mis-parsing it as IEEE-P1363.
 *
 * The caller is responsible for having parsed the header and verified
 * the expected binding tag for the endpoint — this function operates
 * on a fully-typed `ParsedAttestation` and does not re-validate
 * those invariants.
 */
export const verifyAttestationSignature = (parsed: ParsedAttestation): void => {
  assertValidEcP256Spki(parsed.publicKeySPKI);
  const key = importPublicKey(parsed.publicKeySPKI);
  const data = buildSignedMessage(parsed);
  let didVerify: boolean;
  try {
    didVerify = verify(
      'sha256',
      Buffer.from(data),
      { key, dsaEncoding: 'der' },
      Buffer.from(parsed.signature),
    );
  } catch (error) {
    throw new AttestationVerifyError(
      'ATTESTATION_SIGNATURE_INVALID',
      `ECDSA verify threw: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (!didVerify) {
    throw new AttestationVerifyError(
      'ATTESTATION_SIGNATURE_INVALID',
      'ECDSA signature verification returned false',
    );
  }
};
