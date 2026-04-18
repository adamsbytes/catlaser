import { describe, expect, test } from 'bun:test';
import {
  AttestationParseError,
  MAX_BND_WIRE_BYTES,
  decodeAttestationBinding,
} from '~/lib/attestation-binding.ts';

const captureError = (fn: () => unknown): AttestationParseError => {
  try {
    fn();
  } catch (error) {
    if (error instanceof AttestationParseError) {
      return error;
    }
    throw error;
  }
  throw new Error('expected AttestationParseError, got no throw');
};

describe('attestation binding: tag routing', () => {
  test('req: decodes to a request binding with a positive Int64 timestamp', () => {
    const binding = decodeAttestationBinding('req:1734489600');
    expect(binding.tag).toBe('request');
    if (binding.tag !== 'request') {
      throw new Error('narrowing guard');
    }
    expect(binding.timestamp).toBe(1_734_489_600n);
  });

  test('ver: decodes to a verify binding with the raw token payload', () => {
    const binding = decodeAttestationBinding('ver:abc.def.ghi-jkl');
    expect(binding.tag).toBe('verify');
    if (binding.tag !== 'verify') {
      throw new Error('narrowing guard');
    }
    expect(binding.token).toBe('abc.def.ghi-jkl');
  });

  test('sis: decodes to a social binding with the raw nonce payload', () => {
    const binding = decodeAttestationBinding('sis:abc123_-');
    expect(binding.tag).toBe('social');
    if (binding.tag !== 'social') {
      throw new Error('narrowing guard');
    }
    expect(binding.rawNonce).toBe('abc123_-');
  });

  test('out: decodes to a signOut binding with a positive Int64 timestamp', () => {
    const binding = decodeAttestationBinding('out:1');
    expect(binding.tag).toBe('signOut');
    if (binding.tag !== 'signOut') {
      throw new Error('narrowing guard');
    }
    expect(binding.timestamp).toBe(1n);
  });

  test('api: decodes to an api binding with a positive Int64 timestamp', () => {
    const binding = decodeAttestationBinding('api:1734489600');
    expect(binding.tag).toBe('api');
    if (binding.tag !== 'api') {
      throw new Error('narrowing guard');
    }
    expect(binding.timestamp).toBe(1_734_489_600n);
  });

  test('Int64 max (19 digits) is accepted', () => {
    const maxInt64 = '9223372036854775807';
    const binding = decodeAttestationBinding(`req:${maxInt64}`);
    if (binding.tag !== 'request') {
      throw new Error('narrowing guard');
    }
    expect(binding.timestamp).toBe(9_223_372_036_854_775_807n);
  });

  test('unknown tag rejects', () => {
    const err = captureError(() => decodeAttestationBinding('xyz:1'));
    expect(err.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
  });

  test('entirely missing tag rejects', () => {
    const err = captureError(() => decodeAttestationBinding('1734489600'));
    expect(err.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
  });

  test('empty input rejects', () => {
    const err = captureError(() => decodeAttestationBinding(''));
    expect(err.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
  });

  test('tag without colon suffix rejects even if prefix matches', () => {
    const err = captureError(() => decodeAttestationBinding('req:'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('unrecognised four-character prefix still rejects (api: is the only reserved fifth tag)', () => {
    // Step 6 added `api:` as the fifth reserved prefix. No other four-
    // character prefix ending in `:` is accepted; the parser MUST reject
    // anything outside the known five so a forward-compatible binding
    // rollout is purely additive.
    const err = captureError(() => decodeAttestationBinding('xyz:1734489600'));
    expect(err.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
  });
});

describe('attestation binding: timestamp correctness', () => {
  test('zero is rejected (must be positive)', () => {
    const err = captureError(() => decodeAttestationBinding('req:0'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('negative values are rejected (regex excludes minus sign)', () => {
    const err = captureError(() => decodeAttestationBinding('req:-1'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('explicit plus sign is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:+1'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('leading zeros are rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:01'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('leading whitespace is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req: 1'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('trailing whitespace is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:1 '));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('non-decimal notation (hex) is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:0x1'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('scientific notation is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:1e10'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('decimal point is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:1.0'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('embedded non-digit is rejected', () => {
    const err = captureError(() => decodeAttestationBinding('req:12a34'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('value beyond Int64 max rejects (exceeds 19-digit width)', () => {
    const err = captureError(() => decodeAttestationBinding('req:99999999999999999999'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('19-digit value greater than Int64 max rejects on numeric range', () => {
    const err = captureError(() => decodeAttestationBinding('req:9999999999999999999'));
    expect(err.code).toBe('ATTESTATION_BND_BAD_TIMESTAMP');
  });

  test('out: timestamp obeys the same rules as req:', () => {
    expect(captureError(() => decodeAttestationBinding('out:0')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('out:-1')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('out:01')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
  });

  test('api: timestamp obeys the same rules as req: and out:', () => {
    expect(captureError(() => decodeAttestationBinding('api:0')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('api:-1')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('api:01')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('api:')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
    expect(captureError(() => decodeAttestationBinding('api:9999999999999999999')).code).toBe(
      'ATTESTATION_BND_BAD_TIMESTAMP',
    );
  });
});

describe('attestation binding: opaque token/nonce correctness', () => {
  test('empty verify token rejects', () => {
    const err = captureError(() => decodeAttestationBinding('ver:'));
    expect(err.code).toBe('ATTESTATION_BND_EMPTY_TOKEN');
  });

  test('empty social raw nonce rejects', () => {
    const err = captureError(() => decodeAttestationBinding('sis:'));
    expect(err.code).toBe('ATTESTATION_BND_EMPTY_TOKEN');
  });

  test.each([
    ['verify: embedded tab', 'ver:abc\tdef'],
    ['verify: embedded newline', 'ver:abc\ndef'],
    ['verify: embedded CR', 'ver:abc\rdef'],
    ['verify: leading space', 'ver: abc'],
    ['verify: trailing space', 'ver:abc '],
    ['verify: NUL byte', 'ver:abc\u0000'],
    ['verify: DEL byte', 'ver:abc\u007F'],
    ['verify: C1 control', 'ver:abc\u0081'],
    ['verify: NBSP', 'ver:abc\u00A0'],
    ['verify: U+2028 line separator', 'ver:abc\u2028'],
    ['verify: U+2029 paragraph separator', 'ver:abc\u2029'],
    ['verify: ZWNBSP', 'ver:abc\uFEFF'],
    ['social: embedded tab', 'sis:abc\tdef'],
    ['social: embedded newline', 'sis:abc\ndef'],
    ['social: leading space', 'sis: abc'],
  ])('%s rejects', (_label, input) => {
    const err = captureError(() => decodeAttestationBinding(input));
    expect(err.code).toBe('ATTESTATION_BND_CONTROL_CHARS');
  });

  test('non-ASCII printable characters outside the disallowed set are accepted', () => {
    // Emoji, Latin extended, CJK characters are not control/whitespace and
    // should round-trip through the parser untouched. The iOS client's
    // `rawNonce` is base64url-no-pad in practice, so this path is defence-
    // in-depth — but the parser contract is "any non-control text".
    const binding = decodeAttestationBinding('sis:naïve-café-猫-🐈');
    if (binding.tag !== 'social') {
      throw new Error('narrowing guard');
    }
    expect(binding.rawNonce).toBe('naïve-café-猫-🐈');
  });
});

describe('attestation binding: length cap', () => {
  test('wire value exactly at the cap is accepted', () => {
    // `sis:` is 4 bytes, so payload can be MAX_BND_WIRE_BYTES - 4 bytes.
    const payload = 'A'.repeat(MAX_BND_WIRE_BYTES - 4);
    const binding = decodeAttestationBinding(`sis:${payload}`);
    if (binding.tag !== 'social') {
      throw new Error('narrowing guard');
    }
    expect(binding.rawNonce.length).toBe(MAX_BND_WIRE_BYTES - 4);
  });

  test('wire value one byte over the cap rejects', () => {
    const payload = 'A'.repeat(MAX_BND_WIRE_BYTES - 3);
    const err = captureError(() => decodeAttestationBinding(`sis:${payload}`));
    expect(err.code).toBe('ATTESTATION_BND_TOO_LARGE');
  });

  test('multi-byte UTF-8 still enforces the byte-level cap', () => {
    // '🐈' is 4 bytes UTF-8. `sis:` prefix is 4 bytes. 256 cats occupy
    // 4 + 256*4 = 1028 bytes which overshoots 1024.
    const emoji = '🐈'.repeat(256);
    const err = captureError(() => decodeAttestationBinding(`sis:${emoji}`));
    expect(err.code).toBe('ATTESTATION_BND_TOO_LARGE');
  });
});

describe('attestation binding: AttestationParseError shape', () => {
  test('error is an instance of AttestationParseError and carries the code', () => {
    let caught: unknown;
    try {
      decodeAttestationBinding('???');
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(AttestationParseError);
    if (!(caught instanceof AttestationParseError)) {
      throw new Error('narrowing guard');
    }
    expect(caught.code).toBe('ATTESTATION_BND_UNKNOWN_TAG');
    expect(caught.name).toBe('AttestationParseError');
    expect(caught.message.length).toBeGreaterThan(0);
  });
});
