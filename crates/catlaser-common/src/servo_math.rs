//! Pure math for the 200 Hz servo control loop.
//!
//! Angle clamping, exponential interpolation, slew-rate limiting, and
//! angle-to-PWM-tick conversion. All functions are `const`, operate on
//! integers (no floats), and use `i32` internally for headroom. This
//! module lives in `catlaser-common` so it is fully testable on the host.

use crate::constants::{
    CONTROL_LOOP_HZ, DEFAULT_MAX_SLEW_DEG_PER_SEC, PAN_LIMIT_MAX, PAN_LIMIT_MIN, PWM_TICKS_CENTER,
    PWM_TICKS_MAX, PWM_TICKS_MIN, TILT_HORIZON_LIMIT, TILT_HORIZON_LIMIT_PERSON, TILT_LIMIT_MAX,
};

/// Clamps a pan angle to [`PAN_LIMIT_MIN`]..=[`PAN_LIMIT_MAX`].
pub const fn clamp_pan(angle: i16) -> i16 {
    if angle < PAN_LIMIT_MIN {
        PAN_LIMIT_MIN
    } else if angle > PAN_LIMIT_MAX {
        PAN_LIMIT_MAX
    } else {
        angle
    }
}

/// Clamps a tilt angle to the safe range, applying the horizon limit.
///
/// The horizon limit prevents the laser from reaching eye height. When
/// `person_detected` is `true`, the stricter [`TILT_HORIZON_LIMIT_PERSON`]
/// is used instead of [`TILT_HORIZON_LIMIT`]. Positive tilt values point
/// downward.
pub const fn clamp_tilt(angle: i16, person_detected: bool) -> i16 {
    let min = if person_detected {
        TILT_HORIZON_LIMIT_PERSON
    } else {
        TILT_HORIZON_LIMIT
    };
    if angle < min {
        min
    } else if angle > TILT_LIMIT_MAX {
        TILT_LIMIT_MAX
    } else {
        angle
    }
}

/// Interpolates `current` toward `target` using exponential smoothing.
///
/// `alpha` (0-255) maps to 0.0-1.0:
/// - `0`: hold current position (no movement)
/// - `255`: snap to target instantly
///
/// Formula: `current + (target - current) * alpha / 255`.
///
/// All arithmetic is performed in `i32`. The result is always between
/// `current` and `target` (inclusive), so the narrowing cast back to
/// `i16` is safe.
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::integer_division,
    reason = "i32 arithmetic with proven bounds: max |delta| = 65535 (i16 range), \
              * 255 = 16_711_425, fits i32. Result is between current and target \
              (both i16), so i16 truncation cannot occur."
)]
pub const fn interpolate(current: i16, target: i16, alpha: u8) -> i16 {
    let current_w = current as i32;
    let target_w = target as i32;
    let alpha_w = alpha as i32;

    let delta = target_w - current_w;
    let step = delta * alpha_w / 255_i32;

    (current_w + step) as i16
}

/// Limits per-tick movement to the configured maximum slew rate.
///
/// `max_slew_byte` is the raw `max_slew` field from
/// [`ServoCommand`](crate::ServoCommand):
/// - `0`: use [`DEFAULT_MAX_SLEW_DEG_PER_SEC`] (300 deg/sec)
/// - `1`-`255`: max rate in degrees per second
///
/// The per-tick budget is `rate * 100 / CONTROL_LOOP_HZ` hundredths of a
/// degree, floored to a minimum of 1 so that any non-zero rate allows
/// movement.
///
/// Inputs must be valid servo angles (within the clamped range used by
/// the control loop).
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::integer_division,
    reason = "i32 arithmetic with proven bounds: max rate = 300, * 100 / 200 = 150 \
              hundredths/tick. max_per_tick fits in both u32 and i32. current +/- \
              max_per_tick stays within i16 range for valid servo angles \
              (|angle| <= 9000, 9000 + 150 = 9150 < 32767)."
)]
pub const fn slew_limit(current: i16, next: i16, max_slew_byte: u8) -> i16 {
    let rate_deg_sec: u32 = if max_slew_byte == 0_u8 {
        DEFAULT_MAX_SLEW_DEG_PER_SEC as u32
    } else {
        max_slew_byte as u32
    };

    let max_per_tick_raw = rate_deg_sec * 100_u32 / CONTROL_LOOP_HZ;
    // Floor to 1 so any non-zero rate permits at least 0.01 deg/tick.
    let max_per_tick = if max_per_tick_raw == 0_u32 {
        1_i32
    } else {
        max_per_tick_raw as i32
    };

    let current_w = current as i32;
    let next_w = next as i32;
    let delta = next_w - current_w;

    if delta > max_per_tick {
        (current_w + max_per_tick) as i16
    } else if delta < -max_per_tick {
        (current_w - max_per_tick) as i16
    } else {
        next
    }
}

/// Converts a servo angle (hundredths of a degree) to a PWM compare value.
///
/// Linear mapping: -90.00 deg (-9000) maps to [`PWM_TICKS_MIN`], 0 deg
/// maps to [`PWM_TICKS_CENTER`], +90.00 deg (9000) maps to
/// [`PWM_TICKS_MAX`]. Out-of-range angles are clamped to the valid tick
/// range.
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::integer_division,
    reason = "i32 arithmetic: max |angle| = 32768 (i16 range), * 1250 = 40_960_000, \
              fits i32. Result is clamped to [625, 3125] before u16 cast, so \
              truncation and sign loss cannot occur."
)]
pub const fn angle_to_ticks(angle: i16) -> u16 {
    // tick_half_range = (PWM_TICKS_MAX - PWM_TICKS_MIN) / 2 = (3125 - 625) / 2 = 1250
    // angle_half_range = PAN_LIMIT_MAX = 9000 (symmetric +/-90 deg range)
    let tick_half_range = (PWM_TICKS_MAX as i32 - PWM_TICKS_MIN as i32) / 2_i32;
    let angle_half_range = PAN_LIMIT_MAX as i32;
    let center = PWM_TICKS_CENTER as i32;

    let ticks = center + (angle as i32) * tick_half_range / angle_half_range;

    if ticks < PWM_TICKS_MIN as i32 {
        PWM_TICKS_MIN
    } else if ticks > PWM_TICKS_MAX as i32 {
        PWM_TICKS_MAX
    } else {
        ticks as u16
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::{
        CONTROL_LOOP_HZ, DEFAULT_MAX_SLEW_DEG_PER_SEC, PAN_HOME, PAN_LIMIT_MAX, PAN_LIMIT_MIN,
        PWM_TICKS_CENTER, PWM_TICKS_MAX, PWM_TICKS_MIN, TILT_HOME, TILT_HORIZON_LIMIT,
        TILT_HORIZON_LIMIT_PERSON, TILT_LIMIT_MAX,
    };
    use proptest::prelude::*;

    // ---- clamp_pan ----

    #[test]
    fn test_clamp_pan_within_range_passes_through() {
        assert_eq!(clamp_pan(0_i16), 0_i16, "center must pass through");
        assert_eq!(
            clamp_pan(4500_i16),
            4500_i16,
            "positive in-range must pass through"
        );
        assert_eq!(
            clamp_pan(-4500_i16),
            -4500_i16,
            "negative in-range must pass through"
        );
    }

    #[test]
    fn test_clamp_pan_at_limits_passes_through() {
        assert_eq!(
            clamp_pan(PAN_LIMIT_MIN),
            PAN_LIMIT_MIN,
            "min limit must pass through"
        );
        assert_eq!(
            clamp_pan(PAN_LIMIT_MAX),
            PAN_LIMIT_MAX,
            "max limit must pass through"
        );
    }

    #[test]
    fn test_clamp_pan_beyond_limits_clamps() {
        assert_eq!(
            clamp_pan(i16::MIN),
            PAN_LIMIT_MIN,
            "below min must clamp to PAN_LIMIT_MIN"
        );
        assert_eq!(
            clamp_pan(i16::MAX),
            PAN_LIMIT_MAX,
            "above max must clamp to PAN_LIMIT_MAX"
        );
        assert_eq!(
            clamp_pan(-9001_i16),
            PAN_LIMIT_MIN,
            "just below min must clamp"
        );
        assert_eq!(
            clamp_pan(9001_i16),
            PAN_LIMIT_MAX,
            "just above max must clamp"
        );
    }

    // ---- clamp_tilt ----

    #[test]
    fn test_clamp_tilt_normal_within_range() {
        assert_eq!(
            clamp_tilt(4500_i16, false),
            4500_i16,
            "mid-range must pass through"
        );
        assert_eq!(
            clamp_tilt(0_i16, false),
            0_i16,
            "horizontal must pass through"
        );
    }

    #[test]
    fn test_clamp_tilt_normal_at_limits() {
        assert_eq!(
            clamp_tilt(TILT_HORIZON_LIMIT, false),
            TILT_HORIZON_LIMIT,
            "horizon limit must pass through"
        );
        assert_eq!(
            clamp_tilt(TILT_LIMIT_MAX, false),
            TILT_LIMIT_MAX,
            "max limit must pass through"
        );
    }

    #[test]
    fn test_clamp_tilt_normal_below_horizon_clamps() {
        assert_eq!(
            clamp_tilt(-1001_i16, false),
            TILT_HORIZON_LIMIT,
            "below horizon must clamp"
        );
        assert_eq!(
            clamp_tilt(i16::MIN, false),
            TILT_HORIZON_LIMIT,
            "extreme below must clamp to horizon"
        );
    }

    #[test]
    fn test_clamp_tilt_normal_above_max_clamps() {
        assert_eq!(
            clamp_tilt(9001_i16, false),
            TILT_LIMIT_MAX,
            "above max must clamp"
        );
        assert_eq!(
            clamp_tilt(i16::MAX, false),
            TILT_LIMIT_MAX,
            "extreme above must clamp to max"
        );
    }

    #[test]
    fn test_clamp_tilt_person_detected_tightens_limit() {
        assert_eq!(
            clamp_tilt(TILT_HORIZON_LIMIT_PERSON, true),
            TILT_HORIZON_LIMIT_PERSON,
            "person limit must pass through"
        );
        assert_eq!(
            clamp_tilt(499_i16, true),
            TILT_HORIZON_LIMIT_PERSON,
            "just below person limit must clamp"
        );
        assert_eq!(
            clamp_tilt(0_i16, true),
            TILT_HORIZON_LIMIT_PERSON,
            "horizontal must clamp with person detected"
        );
        assert_eq!(
            clamp_tilt(TILT_HORIZON_LIMIT, true),
            TILT_HORIZON_LIMIT_PERSON,
            "normal horizon must clamp with person detected"
        );
    }

    #[test]
    fn test_clamp_tilt_person_detected_above_max_clamps() {
        assert_eq!(
            clamp_tilt(i16::MAX, true),
            TILT_LIMIT_MAX,
            "above max must clamp even with person detected"
        );
    }

    // ---- interpolate ----

    #[test]
    fn test_interpolate_alpha_zero_holds_position() {
        assert_eq!(
            interpolate(1000_i16, 5000_i16, 0_u8),
            1000_i16,
            "alpha=0 must hold current position"
        );
        assert_eq!(
            interpolate(-5000_i16, 5000_i16, 0_u8),
            -5000_i16,
            "alpha=0 must hold with large delta"
        );
    }

    #[test]
    fn test_interpolate_alpha_max_snaps_to_target() {
        assert_eq!(
            interpolate(1000_i16, 5000_i16, 255_u8),
            5000_i16,
            "alpha=255 must snap to target"
        );
        assert_eq!(
            interpolate(-9000_i16, 9000_i16, 255_u8),
            9000_i16,
            "alpha=255 must snap across full range"
        );
    }

    #[test]
    fn test_interpolate_same_position_unchanged() {
        assert_eq!(
            interpolate(4500_i16, 4500_i16, 128_u8),
            4500_i16,
            "same position must remain unchanged"
        );
        assert_eq!(
            interpolate(0_i16, 0_i16, 255_u8),
            0_i16,
            "zero to zero must remain zero"
        );
    }

    #[test]
    fn test_interpolate_known_midpoint() {
        // delta = 2550, alpha = 128
        // step = 2550 * 128 / 255 = 326400 / 255 = 1280
        assert_eq!(
            interpolate(0_i16, 2550_i16, 128_u8),
            1280_i16,
            "alpha=128 with delta=2550 must give step of 1280"
        );
    }

    #[test]
    fn test_interpolate_negative_direction() {
        // delta = -5000 - 5000 = -10000
        // step = -10000 * 128 / 255 = -1280000 / 255 = -5019 (truncated toward zero)
        // result = 5000 + (-5019) = -19
        assert_eq!(
            interpolate(5000_i16, -5000_i16, 128_u8),
            -19_i16,
            "interpolation must work in negative direction"
        );
    }

    #[test]
    fn test_interpolate_small_alpha_small_delta_truncates() {
        // delta = 1, alpha = 1: step = 1 * 1 / 255 = 0
        assert_eq!(
            interpolate(0_i16, 1_i16, 1_u8),
            0_i16,
            "very small delta with small alpha truncates to zero movement"
        );
    }

    // ---- slew_limit ----

    #[test]
    fn test_slew_limit_within_budget_passes_through() {
        // Default: 300 deg/sec -> 150 hundredths/tick. delta = 100.
        assert_eq!(
            slew_limit(0_i16, 100_i16, 0_u8),
            100_i16,
            "small delta must pass through with default rate"
        );
    }

    #[test]
    fn test_slew_limit_positive_excess_clamps() {
        // Default: 150 hundredths/tick. delta = 200 > 150.
        assert_eq!(
            slew_limit(0_i16, 200_i16, 0_u8),
            150_i16,
            "positive excess must clamp to max per tick"
        );
    }

    #[test]
    fn test_slew_limit_negative_excess_clamps() {
        // Default: 150 hundredths/tick. delta = -200 < -150.
        assert_eq!(
            slew_limit(0_i16, -200_i16, 0_u8),
            -150_i16,
            "negative excess must clamp to max per tick"
        );
    }

    #[test]
    fn test_slew_limit_custom_rate() {
        // max_slew=100 -> 100*100/200 = 50 hundredths/tick.
        assert_eq!(
            slew_limit(0_i16, 60_i16, 100_u8),
            50_i16,
            "custom rate must limit correctly"
        );
        assert_eq!(
            slew_limit(0_i16, 30_i16, 100_u8),
            30_i16,
            "within custom budget must pass through"
        );
    }

    #[test]
    fn test_slew_limit_at_exact_boundary() {
        assert_eq!(
            slew_limit(0_i16, 150_i16, 0_u8),
            150_i16,
            "exactly at limit must pass through"
        );
        assert_eq!(
            slew_limit(0_i16, -150_i16, 0_u8),
            -150_i16,
            "exactly at negative limit must pass through"
        );
    }

    #[test]
    fn test_slew_limit_min_rate_allows_movement() {
        // max_slew=1 -> 1*100/200 = 0, floored to 1 hundredth/tick.
        assert_eq!(
            slew_limit(0_i16, 5000_i16, 1_u8),
            1_i16,
            "min slew rate must allow at least 1 hundredth/tick"
        );
    }

    #[test]
    fn test_slew_limit_no_movement_when_at_target() {
        assert_eq!(
            slew_limit(4500_i16, 4500_i16, 0_u8),
            4500_i16,
            "no movement needed when at target"
        );
    }

    // ---- angle_to_ticks ----

    #[test]
    fn test_angle_to_ticks_center() {
        assert_eq!(
            angle_to_ticks(0_i16),
            PWM_TICKS_CENTER,
            "0 degrees must map to center ticks"
        );
    }

    #[test]
    fn test_angle_to_ticks_full_range() {
        assert_eq!(
            angle_to_ticks(9000_i16),
            PWM_TICKS_MAX,
            "+90.00 deg must map to max ticks"
        );
        assert_eq!(
            angle_to_ticks(-9000_i16),
            PWM_TICKS_MIN,
            "-90.00 deg must map to min ticks"
        );
    }

    #[test]
    fn test_angle_to_ticks_home_positions() {
        assert_eq!(
            angle_to_ticks(PAN_HOME),
            PWM_TICKS_CENTER,
            "pan home must map to center"
        );
        // TILT_HOME = 4500 -> 1875 + 4500*1250/9000 = 1875 + 625 = 2500
        assert_eq!(
            angle_to_ticks(TILT_HOME),
            2500_u16,
            "tilt home (45 deg) must map to 2500 ticks"
        );
    }

    #[test]
    fn test_angle_to_ticks_out_of_range_clamps() {
        assert_eq!(
            angle_to_ticks(i16::MAX),
            PWM_TICKS_MAX,
            "extreme positive must clamp to max ticks"
        );
        assert_eq!(
            angle_to_ticks(i16::MIN),
            PWM_TICKS_MIN,
            "extreme negative must clamp to min ticks"
        );
    }

    #[test]
    fn test_angle_to_ticks_45_degrees() {
        // +45.00 deg = 4500 -> 1875 + 4500*1250/9000 = 1875 + 625 = 2500
        assert_eq!(
            angle_to_ticks(4500_i16),
            2500_u16,
            "+45 degrees must map to 2500 ticks"
        );
        // -45.00 deg = -4500 -> 1875 + (-4500)*1250/9000 = 1875 - 625 = 1250
        assert_eq!(
            angle_to_ticks(-4500_i16),
            1250_u16,
            "-45 degrees must map to 1250 ticks"
        );
    }

    // ---- proptest ----

    /// Computes the expected slew budget for property-test assertions.
    #[expect(
        clippy::arithmetic_side_effects,
        clippy::integer_division,
        reason = "test-only helper mirroring production slew_limit logic"
    )]
    fn expected_slew_budget(max_slew: u8) -> u32 {
        let rate: u32 = if max_slew == 0_u8 {
            u32::from(DEFAULT_MAX_SLEW_DEG_PER_SEC)
        } else {
            u32::from(max_slew)
        };
        (rate * 100_u32 / CONTROL_LOOP_HZ).max(1_u32)
    }

    proptest! {
        #[test]
        fn test_clamp_pan_always_within_limits(angle in any::<i16>()) {
            let clamped = clamp_pan(angle);
            prop_assert!(
                clamped >= PAN_LIMIT_MIN,
                "clamped pan {} below PAN_LIMIT_MIN {}", clamped, PAN_LIMIT_MIN,
            );
            prop_assert!(
                clamped <= PAN_LIMIT_MAX,
                "clamped pan {} above PAN_LIMIT_MAX {}", clamped, PAN_LIMIT_MAX,
            );
        }

        #[test]
        fn test_clamp_tilt_always_within_limits(
            angle in any::<i16>(),
            person_detected in any::<bool>(),
        ) {
            let clamped = clamp_tilt(angle, person_detected);
            let min = if person_detected { TILT_HORIZON_LIMIT_PERSON } else { TILT_HORIZON_LIMIT };
            prop_assert!(
                clamped >= min,
                "clamped tilt {} below horizon {}", clamped, min,
            );
            prop_assert!(
                clamped <= TILT_LIMIT_MAX,
                "clamped tilt {} above TILT_LIMIT_MAX {}", clamped, TILT_LIMIT_MAX,
            );
        }

        #[test]
        fn test_clamp_pan_is_idempotent(angle in any::<i16>()) {
            prop_assert_eq!(
                clamp_pan(clamp_pan(angle)),
                clamp_pan(angle),
                "clamping must be idempotent",
            );
        }

        #[test]
        fn test_clamp_tilt_is_idempotent(
            angle in any::<i16>(),
            person_detected in any::<bool>(),
        ) {
            let once = clamp_tilt(angle, person_detected);
            prop_assert_eq!(
                clamp_tilt(once, person_detected),
                once,
                "clamping must be idempotent",
            );
        }

        #[test]
        fn test_interpolate_alpha_zero_returns_current(
            current in -9000_i16..=9000_i16,
            target in -9000_i16..=9000_i16,
        ) {
            prop_assert_eq!(
                interpolate(current, target, 0_u8),
                current,
                "alpha=0 must return current",
            );
        }

        #[test]
        fn test_interpolate_alpha_max_returns_target(
            current in -9000_i16..=9000_i16,
            target in -9000_i16..=9000_i16,
        ) {
            prop_assert_eq!(
                interpolate(current, target, 255_u8),
                target,
                "alpha=255 must return target",
            );
        }

        #[test]
        fn test_interpolate_result_between_endpoints(
            current in -9000_i16..=9000_i16,
            target in -9000_i16..=9000_i16,
            alpha in any::<u8>(),
        ) {
            let result = interpolate(current, target, alpha);
            let lo = current.min(target);
            let hi = current.max(target);
            prop_assert!(
                result >= lo && result <= hi,
                "interpolate({}, {}, {}) = {} must be in [{}..={}]",
                current, target, alpha, result, lo, hi,
            );
        }

        #[test]
        fn test_slew_limit_respects_budget(
            current in -9000_i16..=9000_i16,
            next in -9000_i16..=9000_i16,
            max_slew in any::<u8>(),
        ) {
            let result = slew_limit(current, next, max_slew);
            let budget = expected_slew_budget(max_slew);
            let delta = i32::from(result).abs_diff(i32::from(current));
            prop_assert!(
                delta <= budget,
                "slew_limit({}, {}, {}): |delta| {} exceeds budget {}",
                current, next, max_slew, delta, budget,
            );
        }

        #[test]
        fn test_angle_to_ticks_in_valid_range(angle in -9000_i16..=9000_i16) {
            let ticks = angle_to_ticks(angle);
            prop_assert!(
                ticks >= PWM_TICKS_MIN,
                "ticks {} below PWM_TICKS_MIN {}", ticks, PWM_TICKS_MIN,
            );
            prop_assert!(
                ticks <= PWM_TICKS_MAX,
                "ticks {} above PWM_TICKS_MAX {}", ticks, PWM_TICKS_MAX,
            );
        }

        #[test]
        fn test_angle_to_ticks_is_monotonic(
            a in -9000_i16..=9000_i16,
            b in -9000_i16..=9000_i16,
        ) {
            if a <= b {
                prop_assert!(
                    angle_to_ticks(a) <= angle_to_ticks(b),
                    "monotonicity violated: f({}) = {} > f({}) = {}",
                    a, angle_to_ticks(a), b, angle_to_ticks(b),
                );
            }
        }
    }
}
