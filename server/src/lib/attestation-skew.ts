/**
 * Timestamp-skew enforcement for the `req:` / `sis:` / `out:` / `api:`
 * attestation bindings.
 *
 * The crypto floor (header parse, SPKI validation, per-tag binding match,
 * ECDSA verify) deliberately does not enforce freshness on the timestamped
 * bindings; this module owns that contract and nothing else.
 *
 * The skew contract mirrors the iOS client's signing clock one-to-one: a
 * header is valid when `|now - bnd.timestamp| <= ATTESTATION_SKEW_SECONDS`.
 * Both sides of the window matter — future-dated timestamps are as invalid as
 * stale ones, because either direction is a signal that something is wrong
 * (a clock-skewed device in the future direction, a captured replay in the
 * past direction). The exact ±60s boundary matches the value advertised in
 * ADR-006.
 *
 * The now-source is a dependency so tests can drive the clock deterministically
 * against fixed attestation timestamps. In production `defaultNowSeconds`
 * reads the real wall clock via `Math.floor(Date.now() / 1000)` and returns a
 * `bigint` to match the signed timestamp type exactly (no lossy Number
 * conversions on the comparison path — `bnd.timestamp` is an Int64 on the
 * wire).
 */

/**
 * Inclusive ± skew window, in whole seconds. 60s matches ADR-006 and the
 * iOS `AttestationBinding.request` documentation. Exposed as a `bigint` so
 * all arithmetic on the comparison path stays in the same numeric domain as
 * the signed timestamp itself.
 */
export const ATTESTATION_SKEW_SECONDS = 60n;

export type AttestationSkewCode = 'ATTESTATION_SKEW_EXCEEDED';

export class AttestationSkewError extends Error {
  public readonly code: AttestationSkewCode;

  public constructor(message: string) {
    super(message);
    this.name = 'AttestationSkewError';
    this.code = 'ATTESTATION_SKEW_EXCEEDED';
  }
}

/**
 * Clock source for timestamped-binding enforcement. Returns Unix seconds as a
 * `bigint` so the comparison against `bnd.timestamp` stays exact. In
 * production this reads the real wall clock; in tests, callers substitute a
 * frozen-clock closure.
 */
export type NowSecondsFn = () => bigint;

/**
 * Default now-source. Reads `Date.now()` at call time (NOT at module import)
 * and truncates to whole Unix seconds. Returning a fresh value on every call
 * means a frozen-clock test override that replaces this function operates on
 * each call site independently.
 */
export const defaultNowSeconds: NowSecondsFn = () => BigInt(Math.floor(Date.now() / 1000));

/**
 * Enforce `|now - timestamp| <= ATTESTATION_SKEW_SECONDS`. Throws
 * `AttestationSkewError` with the `ATTESTATION_SKEW_EXCEEDED` code on any
 * violation; returns `void` on success.
 *
 * The error message names both values so a log scrape can diagnose whether the
 * client or the server clock drifted — stale-in-past vs stale-in-future is
 * the load-bearing signal.
 */
export const enforceTimestampSkew = (timestamp: bigint, nowSeconds: bigint): void => {
  const drift = timestamp > nowSeconds ? timestamp - nowSeconds : nowSeconds - timestamp;
  if (drift > ATTESTATION_SKEW_SECONDS) {
    const direction = timestamp > nowSeconds ? 'future' : 'past';
    throw new AttestationSkewError(
      `attestation timestamp ${timestamp.toString()} is ${drift.toString()}s in the ${direction} relative to server time ${nowSeconds.toString()} (max ±${ATTESTATION_SKEW_SECONDS.toString()}s)`,
    );
  }
};
