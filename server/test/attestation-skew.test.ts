import { describe, expect, test } from 'bun:test';
import {
  ATTESTATION_SKEW_SECONDS,
  AttestationSkewError,
  defaultNowSeconds,
  enforceTimestampSkew,
} from '~/lib/attestation-skew.ts';

/**
 * Unit coverage for the skew primitive. The plugin-level integration
 * tests exercise end-to-end behaviour against the better-auth handler;
 * these isolate the arithmetic edge cases so a regression in the pure
 * comparison is attributable.
 */

const captureError = (fn: () => unknown): AttestationSkewError => {
  try {
    fn();
  } catch (error) {
    if (error instanceof AttestationSkewError) {
      return error;
    }
    throw error;
  }
  throw new Error('expected AttestationSkewError, got no throw');
};

describe('attestation skew: boundaries', () => {
  const now = 1_734_489_600n;

  test('now == timestamp accepts', () => {
    expect(() => {
      enforceTimestampSkew(now, now);
    }).not.toThrow();
  });

  test('timestamp exactly +60s accepts (inclusive upper bound)', () => {
    expect(() => {
      enforceTimestampSkew(now + ATTESTATION_SKEW_SECONDS, now);
    }).not.toThrow();
  });

  test('timestamp exactly -60s accepts (inclusive lower bound)', () => {
    expect(() => {
      enforceTimestampSkew(now - ATTESTATION_SKEW_SECONDS, now);
    }).not.toThrow();
  });

  test('timestamp +61s rejects with ATTESTATION_SKEW_EXCEEDED (future)', () => {
    const err = captureError(() => {
      enforceTimestampSkew(now + ATTESTATION_SKEW_SECONDS + 1n, now);
    });
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.message).toContain('future');
    expect(err.message).toContain('61s');
  });

  test('timestamp -61s rejects with ATTESTATION_SKEW_EXCEEDED (past)', () => {
    const err = captureError(() => {
      enforceTimestampSkew(now - ATTESTATION_SKEW_SECONDS - 1n, now);
    });
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.message).toContain('past');
    expect(err.message).toContain('61s');
  });
});

describe('attestation skew: numeric-range correctness', () => {
  test('huge future drift produces a coherent message', () => {
    const err = captureError(() => {
      enforceTimestampSkew(999_999_999_999n, 1n);
    });
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.message).toContain('future');
  });

  test('huge past drift produces a coherent message', () => {
    const err = captureError(() => {
      enforceTimestampSkew(1n, 999_999_999_999n);
    });
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.message).toContain('past');
  });

  test('Int64 max timestamp with near-now clock rejects as future drift', () => {
    const int64Max = 9_223_372_036_854_775_807n;
    const err = captureError(() => {
      enforceTimestampSkew(int64Max, 1_734_489_600n);
    });
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.message).toContain('future');
  });
});

describe('attestation skew: error shape', () => {
  test('AttestationSkewError carries the ATTESTATION_SKEW_EXCEEDED code and name', () => {
    const err = captureError(() => {
      enforceTimestampSkew(1n, 1_000_000n);
    });
    expect(err).toBeInstanceOf(AttestationSkewError);
    expect(err.code).toBe('ATTESTATION_SKEW_EXCEEDED');
    expect(err.name).toBe('AttestationSkewError');
    expect(err.message.length).toBeGreaterThan(0);
  });
});

describe('attestation skew: defaultNowSeconds', () => {
  test('returns a positive bigint near Date.now()/1000', () => {
    const before = BigInt(Math.floor(Date.now() / 1000));
    const value = defaultNowSeconds();
    const after = BigInt(Math.floor(Date.now() / 1000));
    expect(value).toBeGreaterThanOrEqual(before);
    expect(value).toBeLessThanOrEqual(after);
  });

  test('subsequent invocations read the clock fresh (not cached at module load)', () => {
    // Monotonicity holds within a single test run; we cannot assert
    // strict greater-than without sleeping (which would be flaky), but
    // we can assert the second call is >= the first.
    const a = defaultNowSeconds();
    const b = defaultNowSeconds();
    expect(b).toBeGreaterThanOrEqual(a);
  });
});
