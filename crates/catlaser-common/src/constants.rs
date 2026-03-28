//! Safety limits, servo parameters, pin assignments, and protocol constants.

// ---------------------------------------------------------------------------
// Angle limits (i16, hundredths of a degree)
// ---------------------------------------------------------------------------

/// Minimum pan angle (-90.00 deg).
pub const PAN_LIMIT_MIN: i16 = -9000_i16;

/// Maximum pan angle (+90.00 deg).
pub const PAN_LIMIT_MAX: i16 = 9000_i16;

/// Minimum tilt angle (-45.00 deg, upward).
pub const TILT_LIMIT_MIN: i16 = -4500_i16;

/// Maximum tilt angle (+90.00 deg, straight down).
pub const TILT_LIMIT_MAX: i16 = 9000_i16;

// ---------------------------------------------------------------------------
// Safety limits
// ---------------------------------------------------------------------------

/// Hard horizon limit for tilt, enforced by MCU regardless of commands.
///
/// -10.00 deg (10 degrees above horizontal). Allows near-floor play at
/// close range without the laser reaching eye height.
pub const TILT_HORIZON_LIMIT: i16 = -1000_i16;

/// Tightened tilt limit when person detected (flag bit 1 set).
///
/// +5.00 deg (must point below horizontal). MCU applies this stricter
/// clamp whenever the person-detected flag is set.
pub const TILT_HORIZON_LIMIT_PERSON: i16 = 500_i16;

/// Watchdog timeout in milliseconds.
///
/// No valid command within this window triggers: laser off, servos home,
/// dispenser door closed.
pub const WATCHDOG_TIMEOUT_MS: u32 = 500_u32;

// ---------------------------------------------------------------------------
// Servo parameters
// ---------------------------------------------------------------------------

/// PWM frequency for all servos (standard hobby servo).
pub const SERVO_PWM_FREQ_HZ: u32 = 50_u32;

/// Minimum pulse width in microseconds (0 deg).
pub const SERVO_PULSE_MIN_US: u16 = 500_u16;

/// Center pulse width in microseconds (90 deg).
pub const SERVO_PULSE_CENTER_US: u16 = 1500_u16;

/// Maximum pulse width in microseconds (180 deg).
pub const SERVO_PULSE_MAX_US: u16 = 2500_u16;

/// Default max slew rate in degrees per second (when `max_slew` byte is 0).
pub const DEFAULT_MAX_SLEW_DEG_PER_SEC: u16 = 300_u16;

/// Control loop frequency.
pub const CONTROL_LOOP_HZ: u32 = 200_u32;

// ---------------------------------------------------------------------------
// Home position (hundredths of a degree)
// ---------------------------------------------------------------------------

/// Pan home position (center).
pub const PAN_HOME: i16 = 0_i16;

/// Tilt home position (45 deg downward).
pub const TILT_HOME: i16 = 4500_i16;

// ---------------------------------------------------------------------------
// Dispense parameters
// ---------------------------------------------------------------------------

/// Disc rotation counts indexed by dispense tier.
///
/// Tier 0 (low engagement) = 3, tier 1 (moderate) = 5, tier 2 (high) = 7.
/// Variable ratio reinforcement -- Python selects tier based on session metrics.
pub const DISPENSE_ROTATIONS: [u8; 3] = [3_u8, 5_u8, 7_u8];

/// Number of valid dispense tiers.
pub const DISPENSE_TIER_COUNT: u8 = 3_u8;

/// Returns the disc rotation count for the given dispense tier.
///
/// Tiers 0-2 map to 3, 5, and 7 rotations respectively.
/// Returns `None` for out-of-range tiers.
#[must_use]
pub const fn dispense_rotations(tier: u8) -> Option<u8> {
    match tier {
        0 => Some(3_u8),
        1 => Some(5_u8),
        2 => Some(7_u8),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// PWM configuration (50 Hz servo signal at 125 MHz / divider 100)
// ---------------------------------------------------------------------------

/// PWM counter wrap value for 50 Hz servo signal.
///
/// `period = (top + 1) * divider / clk_sys = 25000 * 100 / 125_000_000 = 20 ms`
pub const PWM_TOP: u16 = 24_999_u16;

/// PWM clock divider (integer part) for 50 Hz servo signal.
pub const PWM_DIVIDER: u8 = 100_u8;

/// PWM compare value for minimum servo pulse (500 us).
pub const PWM_TICKS_MIN: u16 = 625_u16;

/// PWM compare value for center servo pulse (1500 us).
pub const PWM_TICKS_CENTER: u16 = 1875_u16;

/// PWM compare value for maximum servo pulse (2500 us).
pub const PWM_TICKS_MAX: u16 = 3125_u16;

/// Converts a pulse width in microseconds to PWM compare ticks.
///
/// `ticks = pulse_us * (PWM_TOP + 1) / period_us = pulse_us * 5 / 4`
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::integer_division,
    reason = "compile-time helper only; max intermediate = 2500 * 5 = 12500, fits u32 and u16"
)]
const fn pulse_us_to_ticks(pulse_us: u16) -> u16 {
    (pulse_us as u32 * 5_u32 / 4_u32) as u16
}

// ---------------------------------------------------------------------------
// UART protocol
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Compile-time safety invariants
// ---------------------------------------------------------------------------

// Person-detected tilt limit must be more restrictive (more positive / more
// downward) than the normal horizon limit.
const _: () = assert!(
    TILT_HORIZON_LIMIT_PERSON > TILT_HORIZON_LIMIT,
    "person-detected tilt limit must be stricter than normal horizon limit"
);

// Home positions must lie within the servo travel range.
const _: () = assert!(
    PAN_HOME >= PAN_LIMIT_MIN && PAN_HOME <= PAN_LIMIT_MAX,
    "PAN_HOME must be within [PAN_LIMIT_MIN, PAN_LIMIT_MAX]"
);
const _: () = assert!(
    TILT_HOME >= TILT_LIMIT_MIN && TILT_HOME <= TILT_LIMIT_MAX,
    "TILT_HOME must be within [TILT_LIMIT_MIN, TILT_LIMIT_MAX]"
);

// Horizon limits must lie within the tilt servo range.
const _: () = assert!(
    TILT_HORIZON_LIMIT >= TILT_LIMIT_MIN && TILT_HORIZON_LIMIT <= TILT_LIMIT_MAX,
    "TILT_HORIZON_LIMIT must be within tilt servo range"
);
const _: () = assert!(
    TILT_HORIZON_LIMIT_PERSON >= TILT_LIMIT_MIN && TILT_HORIZON_LIMIT_PERSON <= TILT_LIMIT_MAX,
    "TILT_HORIZON_LIMIT_PERSON must be within tilt servo range"
);

// Pulse widths must be ordered.
const _: () = assert!(
    SERVO_PULSE_MIN_US < SERVO_PULSE_CENTER_US && SERVO_PULSE_CENTER_US < SERVO_PULSE_MAX_US,
    "servo pulse widths must be ordered: min < center < max"
);

// PWM tick values must match derivation from pulse widths.
const _: () = assert!(
    PWM_TICKS_MIN == pulse_us_to_ticks(SERVO_PULSE_MIN_US),
    "PWM_TICKS_MIN must equal pulse_us_to_ticks(SERVO_PULSE_MIN_US)"
);
const _: () = assert!(
    PWM_TICKS_CENTER == pulse_us_to_ticks(SERVO_PULSE_CENTER_US),
    "PWM_TICKS_CENTER must equal pulse_us_to_ticks(SERVO_PULSE_CENTER_US)"
);
const _: () = assert!(
    PWM_TICKS_MAX == pulse_us_to_ticks(SERVO_PULSE_MAX_US),
    "PWM_TICKS_MAX must equal pulse_us_to_ticks(SERVO_PULSE_MAX_US)"
);
const _: () = assert!(
    PWM_TICKS_MIN < PWM_TICKS_CENTER && PWM_TICKS_CENTER < PWM_TICKS_MAX,
    "PWM tick values must be ordered: min < center < max"
);
const _: () = assert!(
    PWM_TICKS_MAX <= PWM_TOP,
    "maximum servo pulse must fit within PWM period"
);

// ---------------------------------------------------------------------------
// UART protocol
// ---------------------------------------------------------------------------

/// UART baud rate between compute module and MCU.
pub const UART_BAUD: u32 = 115_200_u32;

/// Size of the [`ServoCommand`](crate::ServoCommand) wire format in bytes.
pub const SERVO_CMD_SIZE: usize = 8_usize;

// ---------------------------------------------------------------------------
// RP2040 pin assignments (GPIO numbers)
// ---------------------------------------------------------------------------

/// UART TX (compute module to MCU).
pub const PIN_UART_TX: u8 = 0_u8;

/// UART RX (compute module to MCU).
pub const PIN_UART_RX: u8 = 1_u8;

/// Pan servo PWM.
pub const PIN_SERVO_PAN: u8 = 2_u8;

/// Tilt servo PWM.
pub const PIN_SERVO_TILT: u8 = 3_u8;

/// Disc servo PWM (treat dispenser).
pub const PIN_SERVO_DISC: u8 = 4_u8;

/// Door servo PWM (treat dispenser).
pub const PIN_SERVO_DOOR: u8 = 5_u8;

/// Deflector servo PWM (treat dispenser).
pub const PIN_SERVO_DEFLECTOR: u8 = 6_u8;

/// Laser enable (digital output).
pub const PIN_LASER: u8 = 7_u8;

/// Status LED (RP2040 Pico onboard).
pub const PIN_STATUS_LED: u8 = 25_u8;

/// VBUS voltage sense (ADC input).
pub const PIN_VBUS_SENSE: u8 = 26_u8;

/// Hopper IR break-beam sensor (digital input).
pub const PIN_HOPPER_SENSOR: u8 = 27_u8;

// ---------------------------------------------------------------------------
// Power monitoring
// ---------------------------------------------------------------------------

/// VBUS ADC threshold for power loss detection (millivolts).
///
/// Below this voltage, MCU initiates shutdown: laser off, servos home,
/// signal compute module, then sleep.
pub const VBUS_LOW_THRESHOLD_MV: u16 = 4500_u16;

/// Supercap hold-up time budget in milliseconds.
///
/// MCU must complete the entire shutdown sequence within this window.
pub const SUPERCAP_BUDGET_MS: u32 = 5000_u32;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dispense_rotations_valid_tiers() {
        assert_eq!(
            dispense_rotations(0_u8),
            Some(3_u8),
            "tier 0 should return 3 rotations"
        );
        assert_eq!(
            dispense_rotations(1_u8),
            Some(5_u8),
            "tier 1 should return 5 rotations"
        );
        assert_eq!(
            dispense_rotations(2_u8),
            Some(7_u8),
            "tier 2 should return 7 rotations"
        );
    }

    #[test]
    fn test_dispense_rotations_out_of_range() {
        assert_eq!(
            dispense_rotations(3_u8),
            None,
            "tier 3 should be out of range"
        );
        assert_eq!(
            dispense_rotations(255_u8),
            None,
            "tier 255 should be out of range"
        );
    }

    #[test]
    fn test_dispense_rotations_matches_array() {
        let [r0, r1, r2] = DISPENSE_ROTATIONS;
        assert_eq!(
            dispense_rotations(0_u8),
            Some(r0),
            "function must match array at index 0"
        );
        assert_eq!(
            dispense_rotations(1_u8),
            Some(r1),
            "function must match array at index 1"
        );
        assert_eq!(
            dispense_rotations(2_u8),
            Some(r2),
            "function must match array at index 2"
        );
    }
}
