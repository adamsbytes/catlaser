import { describe, expect, test } from 'bun:test';
import { sign as cryptoSign } from 'node:crypto';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import { ATTESTATION_VERSION, FINGERPRINT_HASH_BYTES } from '~/lib/attestation-header.ts';
import {
  AttestationVerifyError,
  EC_P256_SPKI_PREFIX,
  EC_P256_SPKI_TOTAL_BYTES,
  assertValidEcP256Spki,
  buildSignedMessage,
  verifyAttestationSignature,
} from '~/lib/attestation-verify.ts';
import { createTestDeviceKey, defaultFingerprintHash } from './support/signed-attestation.ts';

const captureError = (fn: () => unknown): AttestationVerifyError => {
  try {
    fn();
  } catch (error) {
    if (error instanceof AttestationVerifyError) {
      return error;
    }
    throw error;
  }
  throw new Error('expected AttestationVerifyError, got no throw');
};

const signedAttestation = (opts: {
  readonly binding: AttestationBinding;
  readonly fingerprintHash?: Uint8Array;
}): ParsedAttestation => {
  const device = createTestDeviceKey();
  const fph = opts.fingerprintHash ?? defaultFingerprintHash();
  const parsedTemplate: ParsedAttestation = {
    version: ATTESTATION_VERSION,
    fingerprintHash: fph,
    publicKeySPKI: device.publicKeySPKI,
    binding: opts.binding,
    signature: new Uint8Array(0),
  };
  const message = buildSignedMessage(parsedTemplate);
  const signature = Uint8Array.from(
    cryptoSign('sha256', Buffer.from(message), { key: device.privateKey, dsaEncoding: 'der' }),
  );
  return { ...parsedTemplate, signature };
};

describe('attestation verify: SPKI structural validation', () => {
  test('well-formed 91-byte P-256 SPKI is accepted', () => {
    const device = createTestDeviceKey();
    expect(device.publicKeySPKI.byteLength).toBe(EC_P256_SPKI_TOTAL_BYTES);
    expect(() => assertValidEcP256Spki(device.publicKeySPKI)).not.toThrow();
  });

  test('short SPKI (under 91 bytes) rejects with ATTESTATION_SPKI_INVALID', () => {
    const shortSpki = new Uint8Array(EC_P256_SPKI_TOTAL_BYTES - 1);
    const err = captureError(() => assertValidEcP256Spki(shortSpki));
    expect(err.code).toBe('ATTESTATION_SPKI_INVALID');
    expect(err.message).toContain('91-byte');
  });

  test('long SPKI (over 91 bytes) rejects with ATTESTATION_SPKI_INVALID', () => {
    const longSpki = new Uint8Array(EC_P256_SPKI_TOTAL_BYTES + 1);
    const err = captureError(() => assertValidEcP256Spki(longSpki));
    expect(err.code).toBe('ATTESTATION_SPKI_INVALID');
  });

  test('SPKI whose prefix bytes differ rejects (curve-confusion / RSA downgrade)', () => {
    // Flip one bit inside the OID that names secp256r1. Total length stays 91
    // so only the structural prefix check is exercised.
    const device = createTestDeviceKey();
    const spki = Uint8Array.from(device.publicKeySPKI);
    const prefixTamperOffset = 10;
    const originalByte = spki[prefixTamperOffset];
    if (originalByte === undefined) {
      throw new Error('SPKI shorter than tamper offset');
    }
    // eslint-disable-next-line no-bitwise
    spki[prefixTamperOffset] = originalByte ^ 0x01;
    const err = captureError(() => assertValidEcP256Spki(spki));
    expect(err.code).toBe('ATTESTATION_SPKI_INVALID');
    expect(err.message).toContain('prefix');
  });

  test('SPKI with compressed point tag (0x02/0x03) rejects', () => {
    const device = createTestDeviceKey();
    const spki = Uint8Array.from(device.publicKeySPKI);
    // Replace the uncompressed-point tag. Total length stays 91 so only the
    // explicit tag check is what rejects.
    spki[EC_P256_SPKI_PREFIX.length] = 0x02;
    const err = captureError(() => assertValidEcP256Spki(spki));
    expect(err.code).toBe('ATTESTATION_SPKI_INVALID');
    expect(err.message).toContain('uncompressed');
  });

  test('SPKI prefix constant matches the published iOS prefix', () => {
    // If this test ever fails, the iOS side (DeviceIdentity.ecP256SPKIPrefix)
    // and the server side have diverged — a drift that would silently accept
    // one side's attestations while the other rejects them.
    expect(EC_P256_SPKI_PREFIX.length).toBe(26);
    expect(EC_P256_SPKI_PREFIX[0]).toBe(0x30);
    expect(EC_P256_SPKI_PREFIX[1]).toBe(0x59);
    expect(EC_P256_SPKI_PREFIX.at(-1)).toBe(0x00);
    expect(EC_P256_SPKI_PREFIX.at(-2)).toBe(0x42);
  });
});

describe('attestation verify: signature over fph || bnd', () => {
  test('valid signature verifies for each binding tag', () => {
    const bindings: readonly AttestationBinding[] = [
      { tag: 'request', timestamp: 1_734_489_600n },
      { tag: 'verify', token: 'abc.def.ghi' },
      { tag: 'social', rawNonce: 'fresh-nonce' },
      { tag: 'signOut', timestamp: 2n },
    ];
    for (const binding of bindings) {
      const attestation = signedAttestation({ binding });
      expect(() => verifyAttestationSignature(attestation)).not.toThrow();
    }
  });

  test('tampered signature rejects with ATTESTATION_SIGNATURE_INVALID', () => {
    const attestation = signedAttestation({
      binding: { tag: 'request', timestamp: 1_734_489_600n },
    });
    const tampered = Uint8Array.from(attestation.signature);
    // Flip the last byte. `dsaEncoding: 'der'` still accepts the bytes as a
    // well-formed DER structure — what fails is the ECDSA math.
    const lastIndex = tampered.length - 1;
    const lastByte = tampered[lastIndex];
    if (lastByte === undefined) {
      throw new Error('signature is empty');
    }
    // eslint-disable-next-line no-bitwise
    tampered[lastIndex] = lastByte ^ 0xff;
    const err = captureError(() =>
      verifyAttestationSignature({ ...attestation, signature: tampered }),
    );
    expect(err.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('fph-mutated attestation rejects — stable sig no longer matches the recomputed message', () => {
    const attestation = signedAttestation({
      binding: { tag: 'verify', token: 'ver-token' },
    });
    const mutatedFph = new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xcd);
    const err = captureError(() =>
      verifyAttestationSignature({ ...attestation, fingerprintHash: mutatedFph }),
    );
    expect(err.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('swapping the binding invalidates the signature even when sig, fph, pk are untouched', () => {
    // Captures the "per-tag binding in the signed bytes" property: iOS's
    // request-time attestation cannot be replayed against the verify
    // endpoint simply by rewriting `bnd` on the wire, because the signed
    // bytes include the binding verbatim.
    const attestation = signedAttestation({
      binding: { tag: 'request', timestamp: 1_734_489_600n },
    });
    const err = captureError(() =>
      verifyAttestationSignature({
        ...attestation,
        binding: { tag: 'verify', token: 'attacker-chosen' },
      }),
    );
    expect(err.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('signature produced by a different key rejects', () => {
    const victim = signedAttestation({
      binding: { tag: 'social', rawNonce: 'victim-nonce' },
    });
    const attacker = createTestDeviceKey();
    const attackerAttestation: ParsedAttestation = {
      ...victim,
      // Signature belongs to the victim key; pk advertises the attacker key.
      publicKeySPKI: attacker.publicKeySPKI,
    };
    const err = captureError(() => verifyAttestationSignature(attackerAttestation));
    expect(err.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('malformed DER in the signature rejects with ATTESTATION_SIGNATURE_INVALID, not a raw throw', () => {
    // Feed a buffer that is not a well-formed DER ECDSA `SEQUENCE { r, s }`.
    // `crypto.verify` with `dsaEncoding: 'der'` throws internally; the module
    // is expected to translate that into the public-facing code.
    const attestation = signedAttestation({
      binding: { tag: 'signOut', timestamp: 1n },
    });
    const err = captureError(() =>
      verifyAttestationSignature({
        ...attestation,
        signature: Uint8Array.from([0x00, 0x01, 0x02, 0x03]),
      }),
    );
    expect(err.code).toBe('ATTESTATION_SIGNATURE_INVALID');
  });

  test('SPKI bytes that are 91 bytes but encode an off-curve point reject as SPKI_INVALID', () => {
    // Build a 91-byte SPKI with the right prefix and tag 0x04 but with an
    // obviously-off-curve point (all zeros for X and Y). `createPublicKey`
    // throws; the module should surface this as ATTESTATION_SPKI_INVALID
    // because the structural layer still owns "I couldn't import this key".
    const attestation = signedAttestation({
      binding: { tag: 'request', timestamp: 1n },
    });
    const bogusSpki = new Uint8Array(EC_P256_SPKI_TOTAL_BYTES);
    bogusSpki.set(EC_P256_SPKI_PREFIX, 0);
    bogusSpki[EC_P256_SPKI_PREFIX.length] = 0x04;
    // X and Y are left at 0x00 → the point (0,0) is not on secp256r1.
    const err = captureError(() =>
      verifyAttestationSignature({ ...attestation, publicKeySPKI: bogusSpki }),
    );
    expect(err.code).toBe('ATTESTATION_SPKI_INVALID');
  });
});

describe('attestation verify: signed-message reconstruction', () => {
  test('buildSignedMessage produces fph || bnd_utf8, exactly', () => {
    const fph = new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0x42);
    const parsed: ParsedAttestation = {
      version: ATTESTATION_VERSION,
      fingerprintHash: fph,
      publicKeySPKI: new Uint8Array(EC_P256_SPKI_TOTAL_BYTES),
      binding: { tag: 'request', timestamp: 1_734_489_600n },
      signature: new Uint8Array(0),
    };
    const message = buildSignedMessage(parsed);
    const expectedBnd = new TextEncoder().encode('req:1734489600');
    expect(message.length).toBe(fph.length + expectedBnd.length);
    expect(message.subarray(0, fph.length)).toEqual(fph);
    expect(message.subarray(fph.length)).toEqual(expectedBnd);
  });

  test('each binding tag produces the documented 4-byte prefix followed by payload', () => {
    const fph = new Uint8Array(FINGERPRINT_HASH_BYTES);
    const cases: readonly [AttestationBinding, string][] = [
      [{ tag: 'request', timestamp: 1n }, 'req:1'],
      [{ tag: 'verify', token: 'the-token' }, 'ver:the-token'],
      [{ tag: 'social', rawNonce: 'a-nonce' }, 'sis:a-nonce'],
      [{ tag: 'signOut', timestamp: 9_999_999_999n }, 'out:9999999999'],
    ];
    for (const [binding, expectedWire] of cases) {
      const message = buildSignedMessage({
        version: ATTESTATION_VERSION,
        fingerprintHash: fph,
        publicKeySPKI: new Uint8Array(EC_P256_SPKI_TOTAL_BYTES),
        binding,
        signature: new Uint8Array(0),
      });
      const tail = new TextDecoder('utf-8').decode(message.subarray(fph.length));
      expect(tail).toBe(expectedWire);
    }
  });
});
