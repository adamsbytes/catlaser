import { describe, expect, test } from 'bun:test';
import type { AttestationBinding } from '~/lib/attestation-binding.ts';
import { AttestationParseError } from '~/lib/attestation-binding.ts';
import type { ParsedAttestation } from '~/lib/attestation-header.ts';
import {
  ATTESTATION_VERSION,
  AttestationHeaderParseError,
  FINGERPRINT_HASH_BYTES,
  MAX_HEADER_VALUE_BYTES,
  MIN_PUBLIC_KEY_BYTES,
  decodeAttestationHeader,
  encodeAttestationHeader,
} from '~/lib/attestation-header.ts';

const wrapInnerAsBase64 = (innerJson: string): string =>
  Buffer.from(innerJson, 'utf8').toString('base64');

const filler = (byteCount: number): string =>
  Buffer.from(new Uint8Array(byteCount).fill(0x11)).toString('base64');

const base64UrlNoPad = (bytes: Uint8Array): string =>
  Buffer.from(bytes)
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

const validFph = (): string => base64UrlNoPad(new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xa));

const captureHeaderError = (fn: () => unknown): AttestationHeaderParseError => {
  try {
    fn();
  } catch (error) {
    if (error instanceof AttestationHeaderParseError) {
      return error;
    }
    throw error;
  }
  throw new Error('expected AttestationHeaderParseError, got no throw');
};

const wellFormedBinding: AttestationBinding = {
  tag: 'social',
  timestamp: 1_734_489_600n,
  rawNonce: 'the-raw-nonce',
};

const wellFormedAttestation: ParsedAttestation = {
  version: ATTESTATION_VERSION,
  fingerprintHash: new Uint8Array(FINGERPRINT_HASH_BYTES).fill(0xab),
  publicKeySPKI: new Uint8Array(MIN_PUBLIC_KEY_BYTES + 10).fill(0x11),
  binding: wellFormedBinding,
  signature: new Uint8Array([0x30, 0x45, 0x02, 0x20, 0x01]),
};

describe('attestation header: round trip', () => {
  test('encode followed by decode returns an equal parsed attestation', () => {
    const header = encodeAttestationHeader(wellFormedAttestation);
    const parsed = decodeAttestationHeader(header);
    expect(parsed.version).toBe(ATTESTATION_VERSION);
    expect(parsed.fingerprintHash).toEqual(wellFormedAttestation.fingerprintHash);
    expect(parsed.publicKeySPKI).toEqual(wellFormedAttestation.publicKeySPKI);
    expect(parsed.signature).toEqual(wellFormedAttestation.signature);
    expect(parsed.binding).toEqual(wellFormedBinding);
  });

  test('canonical key order matches iOS `JSONEncoder.sortedKeys`', () => {
    // The inner JSON must be `{"bnd":...,"fph":...,"pk":...,"sig":...,"v":...}`
    // with keys in lexicographic order. A mismatch here would silently
    // diverge from the iOS wire format and break any future hash-of-payload
    // tooling (log redaction, integrity checks, etc.).
    const header = encodeAttestationHeader(wellFormedAttestation);
    const inner = Buffer.from(header, 'base64').toString('utf8');
    expect(inner.startsWith('{"bnd":')).toBe(true);
    const keyOrder = [...inner.matchAll(/"(?<key>bnd|fph|pk|sig|v)"/gv)].map(
      (match) => match.groups?.['key'],
    );
    expect(keyOrder).toEqual(['bnd', 'fph', 'pk', 'sig', 'v']);
  });

  test('each supported binding tag survives a round trip', () => {
    const bindings: readonly AttestationBinding[] = [
      { tag: 'request', timestamp: 1_734_489_600n },
      { tag: 'verify', token: 'magic-link-token-value' },
      { tag: 'social', timestamp: 1_734_489_600n, rawNonce: 'a-raw-nonce' },
      { tag: 'signOut', timestamp: 1n },
      { tag: 'api', timestamp: 1_734_489_600n },
    ];
    for (const binding of bindings) {
      const header = encodeAttestationHeader({ ...wellFormedAttestation, binding });
      const parsed = decodeAttestationHeader(header);
      expect(parsed.binding).toEqual(binding);
    }
  });
});

describe('attestation header: size caps', () => {
  test('empty input rejects with ATTESTATION_HEADER_EMPTY', () => {
    const err = captureHeaderError(() => decodeAttestationHeader(''));
    expect(err.code).toBe('ATTESTATION_HEADER_EMPTY');
  });

  test('oversized input rejects with ATTESTATION_HEADER_TOO_LARGE', () => {
    // Padding base64 to length MAX + 4 so the overflow check fires before
    // the base64 decoder sees it.
    const oversized = 'A'.repeat(MAX_HEADER_VALUE_BYTES + 4);
    const err = captureHeaderError(() => decodeAttestationHeader(oversized));
    expect(err.code).toBe('ATTESTATION_HEADER_TOO_LARGE');
  });
});

describe('attestation header: outer base64 correctness', () => {
  test.each([
    ['non-base64 characters', 'not@valid_base64!'],
    ['base64 with whitespace', 'AAAA AAAA'],
    ['base64 length not multiple of 4', 'AAAAA'],
    ['base64 with misplaced padding', 'A=AA'],
    ['base64 with three equals signs', 'AAA==='],
  ])('rejects outer %s', (_label, input) => {
    const err = captureHeaderError(() => decodeAttestationHeader(input));
    expect(err.code).toBe('ATTESTATION_OUTER_BASE64');
  });
});

describe('attestation header: inner payload shape', () => {
  test('inner JSON that is not an object rejects with ATTESTATION_PAYLOAD_SHAPE', () => {
    const header = wrapInnerAsBase64('42');
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_SHAPE');
  });

  test('inner JSON that is an array rejects', () => {
    const header = wrapInnerAsBase64('[]');
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_SHAPE');
  });

  test('inner JSON that is null rejects', () => {
    const header = wrapInnerAsBase64('null');
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_SHAPE');
  });

  test('inner JSON with unexpected keys rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"AAAA","pk":"AAAA","sig":"AAAA","v":4,"extra":true}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_SHAPE');
  });

  test.each([
    ['bnd as number', `{"bnd":1,"fph":"X","pk":"X","sig":"X","v":4}`],
    ['fph as number', `{"bnd":"sis:1:x","fph":1,"pk":"X","sig":"X","v":4}`],
    ['pk as null', `{"bnd":"sis:1:x","fph":"X","pk":null,"sig":"X","v":4}`],
    ['sig as boolean', `{"bnd":"sis:1:x","fph":"X","pk":"X","sig":true,"v":4}`],
    ['v as string', `{"bnd":"sis:1:x","fph":"X","pk":"X","sig":"X","v":"4"}`],
    ['v as float', `{"bnd":"sis:1:x","fph":"X","pk":"X","sig":"X","v":4.5}`],
  ])('%s rejects with ATTESTATION_PAYLOAD_SHAPE', (_label, inner) => {
    const header = wrapInnerAsBase64(inner);
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_SHAPE');
  });

  test('inner JSON that does not parse rejects with ATTESTATION_PAYLOAD_JSON', () => {
    const header = wrapInnerAsBase64('{not-json');
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_JSON');
  });

  test('inner bytes that are not valid UTF-8 rejects', () => {
    // 0xC3 0x28 is an invalid UTF-8 two-byte sequence (the continuation byte
    // lacks the 10xxxxxx pattern).
    const badUtf8 = Buffer.from([0xc3, 0x28]).toString('base64');
    const err = captureHeaderError(() => decodeAttestationHeader(badUtf8));
    expect(err.code).toBe('ATTESTATION_PAYLOAD_JSON');
  });
});

describe('attestation header: version gate', () => {
  test('v !== 4 rejects with ATTESTATION_VERSION_MISMATCH', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":2}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_VERSION_MISMATCH');
  });

  test('v === 3 (retired nonce-only social binding) rejects', () => {
    // v3 is the immediate predecessor version whose `sis:` binding carried
    // only the raw nonce with no timestamp. A v3 client reaching a v4
    // server would silently mismatch the skew contract, so the version
    // gate must refuse v3 outright rather than let a malformed `sis:`
    // parse into the new shape.
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:x","fph":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":3}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_VERSION_MISMATCH');
  });

  test('v === 1 (pre-attestation wire format) rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":1}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_VERSION_MISMATCH');
  });
});

describe('attestation header: fph byte length', () => {
  test('fph that decodes to fewer than 32 bytes rejects', () => {
    const shortFph = base64UrlNoPad(new Uint8Array(31).fill(0xaa));
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${shortFph}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_FPH_INVALID');
  });

  test('fph that decodes to more than 32 bytes rejects', () => {
    const longFph = base64UrlNoPad(new Uint8Array(33).fill(0xaa));
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${longFph}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_FPH_INVALID');
  });

  test('fph with invalid base64url character rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"!!","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_FPH_INVALID');
  });

  test('fph with a length 1 mod 4 rejects (base64url cannot terminate there)', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"A","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_FPH_INVALID');
  });

  test('fph that contains traditional base64 characters rejects', () => {
    // '+' and '/' are not in the base64url alphabet — must be '-' and '_'.
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"ab+/","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_FPH_INVALID');
  });
});

describe('attestation header: pk byte length', () => {
  test('pk under the minimum rejects', () => {
    const shortPk = filler(MIN_PUBLIC_KEY_BYTES - 1);
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${validFph()}","pk":"${shortPk}","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PK_INVALID');
  });

  test('pk with malformed base64 rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${validFph()}","pk":"A!!A","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PK_INVALID');
  });

  test('pk that is empty rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${validFph()}","pk":"","sig":"AAAA","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_PK_INVALID');
  });
});

describe('attestation header: sig byte length', () => {
  test('sig with malformed base64 rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${validFph()}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"A!!A","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_SIG_INVALID');
  });

  test('sig that is empty rejects', () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"sis:1:x","fph":"${validFph()}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"","v":4}`,
    );
    const err = captureHeaderError(() => decodeAttestationHeader(header));
    expect(err.code).toBe('ATTESTATION_SIG_INVALID');
  });
});

describe('attestation header: binding failure propagates AttestationParseError', () => {
  test("an unknown tag inside 'bnd' surfaces as AttestationParseError", () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"xyz:1","fph":"${validFph()}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    let caught: unknown;
    try {
      decodeAttestationHeader(header);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(AttestationParseError);
    if (!(caught instanceof AttestationParseError)) {
      throw new Error('narrowing guard');
    }
    expect(caught.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
  });

  test("a malformed timestamp inside 'bnd' surfaces as AttestationParseError", () => {
    const header = wrapInnerAsBase64(
      `{"bnd":"req:01","fph":"${validFph()}","pk":"${filler(MIN_PUBLIC_KEY_BYTES)}","sig":"AAAA","v":4}`,
    );
    let caught: unknown;
    try {
      decodeAttestationHeader(header);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(AttestationParseError);
    if (!(caught instanceof AttestationParseError)) {
      throw new Error('narrowing guard');
    }
    expect(caught.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });
});
