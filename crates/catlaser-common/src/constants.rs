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

/// Software watchdog check frequency.
///
/// The watchdog task checks command freshness at this rate and feeds the
/// RP2040 hardware watchdog each tick. 100 Hz gives at most 10 ms of
/// additional detection latency beyond the timeout window.
pub const WATCHDOG_CHECK_HZ: u32 = 100_u32;

/// Returns `true` if the compute module has not sent a valid command
/// within the timeout window.
///
/// Stale in two cases:
/// - `last_rx_ticks == 0`: no command has ever been received since boot
/// - Elapsed time since `last_rx_ticks` exceeds `timeout_ticks`
#[must_use]
pub const fn is_command_stale(last_rx_ticks: u64, now_ticks: u64, timeout_ticks: u64) -> bool {
    if last_rx_ticks == 0_u64 {
        return true;
    }
    now_ticks.saturating_sub(last_rx_ticks) > timeout_ticks
}

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
// Dispenser servo positions (hundredths of a degree)
// ---------------------------------------------------------------------------

/// Disc servo closed position (holes misaligned, resting state).
///
/// The disc rests with holes misaligned as a secondary gravity-closed
/// gate in series with the chute door.
pub const DISC_CLOSED: i16 = 0_i16;

/// Disc servo open position (holes aligned, one treat drops through).
pub const DISC_OPEN: i16 = 6000_i16;

/// Door servo closed position (gravity rest, fail-safe default).
///
/// The chute door closes by gravity when the servo releases or loses
/// power. This position matches the gravity rest angle.
pub const DOOR_CLOSED: i16 = 0_i16;

/// Door servo open position (pulled up against gravity by servo).
pub const DOOR_OPEN: i16 = -6000_i16;

/// Deflector center (idle) position.
pub const DEFLECTOR_CENTER: i16 = 0_i16;

/// Deflector position routing treats to the left chute exit.
pub const DEFLECTOR_LEFT: i16 = -4500_i16;

/// Deflector position routing treats to the right chute exit.
pub const DEFLECTOR_RIGHT: i16 = 4500_i16;

// ---------------------------------------------------------------------------
// Dispenser timing (milliseconds)
// ---------------------------------------------------------------------------

/// Time for the disc servo to travel between open and closed positions.
pub const DISC_TRAVEL_MS: u32 = 200_u32;

/// Dwell time at disc open position for one treat to fall through.
pub const DISC_DWELL_MS: u32 = 300_u32;

/// Time for the door servo to travel between open and closed positions.
pub const DOOR_TRAVEL_MS: u32 = 200_u32;

/// Dwell time with door open for accumulated treats to drop to the floor.
pub const DOOR_OPEN_DWELL_MS: u32 = 500_u32;

/// Time for the deflector servo to reach and settle at target position.
pub const DEFLECTOR_SETTLE_MS: u32 = 250_u32;

/// Maximum allowed duration for the entire dispense sequence.
///
/// If the sequence exceeds this duration, it is aborted as a potential
/// mechanical jam. The MCU closes the door and returns to idle.
pub const DISPENSE_JAM_TIMEOUT_MS: u32 = 10_000_u32;

/// Computes the expected duration of a complete dispense sequence for
/// the given number of disc rotations.
///
/// Sequence: deflector settle → N × (disc travel + dwell + travel) →
/// door travel + dwell + travel → deflector return.
#[must_use]
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    reason = "all values are small constants: per_rotation = 700, max disc_phase = 255 * 700 = \
              178_500, max total = 179_900, all fit u32. u8-to-u32 widening never truncates."
)]
pub const fn dispense_sequence_duration_ms(rotations: u8) -> u32 {
    let per_rotation = DISC_TRAVEL_MS + DISC_DWELL_MS + DISC_TRAVEL_MS;
    let disc_phase = (rotations as u32) * per_rotation;
    let door_phase = DOOR_TRAVEL_MS + DOOR_OPEN_DWELL_MS + DOOR_TRAVEL_MS;
    DEFLECTOR_SETTLE_MS + disc_phase + door_phase + DEFLECTOR_SETTLE_MS
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
// Hopper sensor
// ---------------------------------------------------------------------------

/// Hopper IR break-beam sensor polling frequency.
///
/// 2 Hz = 500 ms interval. The hopper level changes only during dispense
/// sequences (at most every few seconds), so high-frequency polling wastes
/// cycles for no benefit.
pub const HOPPER_POLL_HZ: u32 = 2_u32;

/// Number of consecutive "empty" sensor readings required before the MCU
/// reports the hopper as empty.
///
/// At [`HOPPER_POLL_HZ`] = 2 Hz, a threshold of 4 means 2 seconds of
/// sustained empty readings before the state transitions. A single "present"
/// reading immediately resets the counter. This asymmetry is deliberate:
/// false-empty blocks autonomous sessions (bad), false-present only causes
/// a dry dispense cycle (tolerable).
pub const HOPPER_DEBOUNCE_THRESHOLD: u8 = 4_u8;

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

/// VBUS polling frequency.
///
/// 10 Hz = 100 ms interval. In the worst case (power drops just after a
/// poll), the next poll detects it within 100 ms — meeting the laser-kill
/// deadline from the product spec.
pub const VBUS_POLL_HZ: u32 = 10_u32;

/// VBUS voltage divider scaling factor.
///
/// The custom PCB feeds VBUS through a resistive divider (200 K high-side,
/// 100 K low-side) to GPIO26 / ADC0. Actual VBUS voltage equals the ADC
/// pin voltage multiplied by this factor.
pub const VBUS_DIVIDER_FACTOR: u32 = 3_u32;

/// ADC reference voltage in millivolts (RP2040 internal 3.3 V reference).
pub const ADC_REF_MV: u32 = 3300_u32;

/// ADC maximum raw reading (12-bit SAR, 0–4095).
pub const ADC_MAX_RAW: u16 = 4095_u16;

/// Shutdown signal byte sent to the compute module over UART TX on power loss.
///
/// The compute module's serial handler watches for this byte to initiate a
/// filesystem-safe shutdown within the supercap hold-up window.
pub const SHUTDOWN_SIGNAL: u8 = 0x53_u8;

/// Converts a raw 12-bit ADC reading to VBUS voltage in millivolts,
/// accounting for the voltage divider on the sense pin.
///
/// Formula: `raw * ADC_REF_MV * VBUS_DIVIDER_FACTOR / ADC_MAX_RAW`
///
/// Integer division truncates toward zero, making the reported voltage
/// slightly lower than actual — the safe direction for a low-threshold
/// comparator (triggers shutdown marginally early).
#[must_use]
#[expect(
    clippy::arithmetic_side_effects,
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    clippy::integer_division,
    reason = "max intermediate = 4095 * 3300 * 3 = 40_540_500 fits u32; max output = 9900 fits u16"
)]
pub const fn raw_to_vbus_mv(raw: u16) -> u16 {
    (raw as u32 * ADC_REF_MV * VBUS_DIVIDER_FACTOR / ADC_MAX_RAW as u32) as u16
}

// ---------------------------------------------------------------------------
// Compile-time power monitoring invariants
// ---------------------------------------------------------------------------

// VBUS threshold must be detectable by the ADC.
const _: () = assert!(
    VBUS_LOW_THRESHOLD_MV < raw_to_vbus_mv(ADC_MAX_RAW),
    "VBUS low threshold must be below maximum measurable voltage"
);

// Conversion boundaries must be consistent.
const _: () = assert!(
    raw_to_vbus_mv(0_u16) == 0_u16,
    "raw ADC value 0 must map to 0 mV"
);

// Poll rate must be nonzero.
const _: () = assert!(VBUS_POLL_HZ > 0_u32, "VBUS poll rate must be nonzero");

// ---------------------------------------------------------------------------
// Compile-time dispenser invariants
// ---------------------------------------------------------------------------

// All dispenser servo angles must be within the valid range.
const _: () = assert!(
    DISC_CLOSED >= PAN_LIMIT_MIN && DISC_CLOSED <= PAN_LIMIT_MAX,
    "DISC_CLOSED must be within servo range"
);
const _: () = assert!(
    DISC_OPEN >= PAN_LIMIT_MIN && DISC_OPEN <= PAN_LIMIT_MAX,
    "DISC_OPEN must be within servo range"
);
const _: () = assert!(
    DOOR_CLOSED >= PAN_LIMIT_MIN && DOOR_CLOSED <= PAN_LIMIT_MAX,
    "DOOR_CLOSED must be within servo range"
);
const _: () = assert!(
    DOOR_OPEN >= PAN_LIMIT_MIN && DOOR_OPEN <= PAN_LIMIT_MAX,
    "DOOR_OPEN must be within servo range"
);
const _: () = assert!(
    DEFLECTOR_CENTER >= PAN_LIMIT_MIN && DEFLECTOR_CENTER <= PAN_LIMIT_MAX,
    "DEFLECTOR_CENTER must be within servo range"
);
const _: () = assert!(
    DEFLECTOR_LEFT >= PAN_LIMIT_MIN && DEFLECTOR_LEFT <= PAN_LIMIT_MAX,
    "DEFLECTOR_LEFT must be within servo range"
);
const _: () = assert!(
    DEFLECTOR_RIGHT >= PAN_LIMIT_MIN && DEFLECTOR_RIGHT <= PAN_LIMIT_MAX,
    "DEFLECTOR_RIGHT must be within servo range"
);

// Disc positions must be distinct.
const _: () = assert!(DISC_CLOSED != DISC_OPEN, "disc open and closed must differ");

// Door positions must be distinct.
const _: () = assert!(DOOR_CLOSED != DOOR_OPEN, "door open and closed must differ");

// Deflector positions must be pairwise distinct.
const _: () = assert!(
    DEFLECTOR_LEFT != DEFLECTOR_RIGHT,
    "deflector left and right must differ"
);
const _: () = assert!(
    DEFLECTOR_LEFT != DEFLECTOR_CENTER,
    "deflector left and center must differ"
);
const _: () = assert!(
    DEFLECTOR_RIGHT != DEFLECTOR_CENTER,
    "deflector right and center must differ"
);

// Maximum dispense sequence must complete within jam timeout.
const _: () = assert!(
    dispense_sequence_duration_ms(7_u8) < DISPENSE_JAM_TIMEOUT_MS,
    "maximum dispense sequence (7 rotations) must complete within jam timeout"
);

// Timing values must be nonzero.
const _: () = assert!(DISC_TRAVEL_MS > 0_u32, "disc travel time must be nonzero");
const _: () = assert!(DISC_DWELL_MS > 0_u32, "disc dwell time must be nonzero");
const _: () = assert!(DOOR_TRAVEL_MS > 0_u32, "door travel time must be nonzero");
const _: () = assert!(
    DOOR_OPEN_DWELL_MS > 0_u32,
    "door open dwell must be nonzero"
);
const _: () = assert!(
    DEFLECTOR_SETTLE_MS > 0_u32,
    "deflector settle must be nonzero"
);
const _: () = assert!(
    DISPENSE_JAM_TIMEOUT_MS > 0_u32,
    "jam timeout must be nonzero"
);

// ---------------------------------------------------------------------------
// Compile-time hopper invariants
// ---------------------------------------------------------------------------

// Poll rate must be nonzero.
const _: () = assert!(HOPPER_POLL_HZ > 0_u32, "hopper poll rate must be nonzero");

// Debounce threshold must be nonzero (at least one reading required).
const _: () = assert!(
    HOPPER_DEBOUNCE_THRESHOLD > 0_u8,
    "hopper debounce threshold must be nonzero"
);

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // --- is_command_stale ---

    #[test]
    fn test_stale_no_command_ever_received() {
        assert!(
            is_command_stale(0_u64, 1_000_000_u64, 500_000_u64),
            "zero last_rx (never received) must be stale"
        );
    }

    #[test]
    fn test_stale_no_command_at_boot() {
        assert!(
            is_command_stale(0_u64, 0_u64, 500_000_u64),
            "zero last_rx must be stale even at time zero"
        );
    }

    #[test]
    fn test_fresh_just_received() {
        assert!(
            !is_command_stale(1000_u64, 1000_u64, 500_000_u64),
            "command at current time must be fresh"
        );
    }

    #[test]
    fn test_fresh_within_timeout() {
        // elapsed = 500_999 - 1000 = 499_999, within 500_000 timeout
        assert!(
            !is_command_stale(1000_u64, 500_999_u64, 500_000_u64),
            "elapsed within timeout must be fresh"
        );
    }

    #[test]
    fn test_fresh_at_exact_timeout_boundary() {
        // elapsed = 501_000 - 1000 = 500_000, exactly at timeout (> not >=)
        assert!(
            !is_command_stale(1000_u64, 501_000_u64, 500_000_u64),
            "elapsed at exact timeout must be fresh (strict greater-than)"
        );
    }

    #[test]
    fn test_stale_one_tick_past_timeout() {
        // elapsed = 501_001 - 1000 = 500_001, one tick past timeout
        assert!(
            is_command_stale(1000_u64, 501_001_u64, 500_000_u64),
            "one tick past timeout must be stale"
        );
    }

    #[test]
    fn test_stale_well_past_timeout() {
        assert!(
            is_command_stale(1000_u64, 10_001_000_u64, 500_000_u64),
            "well past timeout must be stale"
        );
    }

    #[test]
    fn test_fresh_now_before_last_rx_saturates_to_zero() {
        // Degenerate case: now < last_rx. saturating_sub returns 0, which is <= timeout.
        assert!(
            !is_command_stale(1_000_000_u64, 500_u64, 500_000_u64),
            "saturating_sub handles now < last_rx without underflow"
        );
    }

    // --- dispense_rotations ---

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

    // --- is_command_stale proptest ---

    proptest! {
        #[test]
        fn test_stale_never_received_always_stale(
            now in any::<u64>(),
            timeout in 1_u64..=4_000_000_000_u64,
        ) {
            prop_assert!(
                is_command_stale(0_u64, now, timeout),
                "zero last_rx must always be stale",
            );
        }

        #[test]
        fn test_stale_within_timeout_always_fresh(
            last_rx in 1_u64..=4_000_000_000_u64,
            elapsed in 0_u64..500_000_u64,
        ) {
            let now = last_rx.saturating_add(elapsed);
            prop_assert!(
                !is_command_stale(last_rx, now, 500_000_u64),
                "elapsed {} within 500000 timeout must be fresh", elapsed,
            );
        }

        #[test]
        fn test_stale_past_timeout_always_stale(
            last_rx in 1_u64..=4_000_000_000_u64,
            overshoot in 1_u64..1_000_000_u64,
        ) {
            let now = last_rx
                .saturating_add(500_000_u64)
                .saturating_add(overshoot);
            prop_assert!(
                is_command_stale(last_rx, now, 500_000_u64),
                "overshoot {} past timeout must be stale", overshoot,
            );
        }
    }

    // --- raw_to_vbus_mv ---

    #[test]
    fn test_vbus_mv_zero_raw_is_zero() {
        assert_eq!(raw_to_vbus_mv(0_u16), 0_u16, "raw 0 must map to 0 mV");
    }

    #[test]
    fn test_vbus_mv_max_raw_is_full_scale() {
        assert_eq!(
            raw_to_vbus_mv(ADC_MAX_RAW),
            9900_u16,
            "raw 4095 must map to 9900 mV (3300 * 3)"
        );
    }

    #[test]
    fn test_vbus_mv_midpoint() {
        // raw 2048 ≈ half-scale: 2048 * 9900 / 4095 = 4951 (truncated)
        assert_eq!(
            raw_to_vbus_mv(2048_u16),
            4951_u16,
            "midpoint raw value must map to approximately half of full-scale"
        );
    }

    #[test]
    fn test_vbus_mv_threshold_boundary_below() {
        // Highest raw value that converts to below VBUS_LOW_THRESHOLD_MV.
        // raw 1861 → 1861 * 9900 / 4095 = 4499
        assert!(
            raw_to_vbus_mv(1861_u16) < VBUS_LOW_THRESHOLD_MV,
            "raw 1861 must convert below the 4500 mV threshold"
        );
    }

    #[test]
    fn test_vbus_mv_threshold_boundary_above() {
        // Lowest raw value that converts to at or above VBUS_LOW_THRESHOLD_MV.
        // raw 1862 → 1862 * 9900 / 4095 = 4501
        assert!(
            raw_to_vbus_mv(1862_u16) >= VBUS_LOW_THRESHOLD_MV,
            "raw 1862 must convert at or above the 4500 mV threshold"
        );
    }

    proptest! {
        #[test]
        fn test_vbus_mv_bounded(raw in 0_u16..=ADC_MAX_RAW) {
            let mv = raw_to_vbus_mv(raw);
            prop_assert!(
                mv <= 9900_u16,
                "raw {} produced {} mV, exceeds full-scale 9900 mV", raw, mv,
            );
        }

        #[test]
        fn test_vbus_mv_monotonic(a in 0_u16..ADC_MAX_RAW) {
            let b = a.saturating_add(1_u16);
            prop_assert!(
                raw_to_vbus_mv(a) <= raw_to_vbus_mv(b),
                "raw_to_vbus_mv must be non-decreasing: f({}) = {}, f({}) = {}",
                a, raw_to_vbus_mv(a), b, raw_to_vbus_mv(b),
            );
        }

        #[test]
        fn test_vbus_mv_zero_iff_raw_zero(raw in 0_u16..=ADC_MAX_RAW) {
            let mv = raw_to_vbus_mv(raw);
            if raw == 0_u16 {
                prop_assert_eq!(mv, 0_u16, "raw 0 must produce 0 mV");
            } else {
                prop_assert!(mv > 0_u16, "nonzero raw {} must produce nonzero mV", raw);
            }
        }
    }

    // --- dispense_sequence_duration_ms ---

    #[test]
    fn test_dispense_duration_tier_0() {
        // 250 + 3*(200+300+200) + 200+500+200 + 250 = 3500
        assert_eq!(
            dispense_sequence_duration_ms(3_u8),
            3500_u32,
            "tier 0 (3 rotations) duration must be 3500ms"
        );
    }

    #[test]
    fn test_dispense_duration_tier_1() {
        // 250 + 5*700 + 900 + 250 = 4900
        assert_eq!(
            dispense_sequence_duration_ms(5_u8),
            4900_u32,
            "tier 1 (5 rotations) duration must be 4900ms"
        );
    }

    #[test]
    fn test_dispense_duration_tier_2() {
        // 250 + 7*700 + 900 + 250 = 6300
        assert_eq!(
            dispense_sequence_duration_ms(7_u8),
            6300_u32,
            "tier 2 (7 rotations) duration must be 6300ms"
        );
    }

    #[test]
    fn test_dispense_duration_zero_rotations() {
        // 250 + 0 + 900 + 250 = 1400 (deflector + door + deflector, no disc)
        assert_eq!(
            dispense_sequence_duration_ms(0_u8),
            1400_u32,
            "0 rotations must still include door and deflector phases"
        );
    }

    #[test]
    fn test_dispense_duration_all_tiers_within_jam_timeout() {
        for &rotations in &DISPENSE_ROTATIONS {
            let duration = dispense_sequence_duration_ms(rotations);
            assert!(
                duration < DISPENSE_JAM_TIMEOUT_MS,
                "tier with {rotations} rotations ({duration}ms) exceeds jam timeout ({DISPENSE_JAM_TIMEOUT_MS}ms)",
            );
        }
    }

    #[test]
    fn test_dispense_duration_matches_rotation_function() {
        let [r0, r1, r2] = DISPENSE_ROTATIONS;
        assert_eq!(
            dispense_rotations(0_u8).map(dispense_sequence_duration_ms),
            Some(dispense_sequence_duration_ms(r0)),
            "tier 0 duration must match array"
        );
        assert_eq!(
            dispense_rotations(1_u8).map(dispense_sequence_duration_ms),
            Some(dispense_sequence_duration_ms(r1)),
            "tier 1 duration must match array"
        );
        assert_eq!(
            dispense_rotations(2_u8).map(dispense_sequence_duration_ms),
            Some(dispense_sequence_duration_ms(r2)),
            "tier 2 duration must match array"
        );
    }

    #[test]
    fn test_dispenser_angles_produce_valid_pwm() {
        use crate::servo_math;

        for angle in [
            DISC_CLOSED,
            DISC_OPEN,
            DOOR_CLOSED,
            DOOR_OPEN,
            DEFLECTOR_CENTER,
            DEFLECTOR_LEFT,
            DEFLECTOR_RIGHT,
        ] {
            let ticks = servo_math::angle_to_ticks(angle);
            assert!(
                (PWM_TICKS_MIN..=PWM_TICKS_MAX).contains(&ticks),
                "dispenser angle {angle} produces ticks {ticks} outside valid range [{PWM_TICKS_MIN}, {PWM_TICKS_MAX}]",
            );
        }
    }

    proptest! {
        #[test]
        fn test_dispense_duration_monotonic(a in 0_u8..=254_u8) {
            let b = a.saturating_add(1_u8);
            prop_assert!(
                dispense_sequence_duration_ms(a) <= dispense_sequence_duration_ms(b),
                "duration must be non-decreasing: f({}) = {}, f({}) = {}",
                a, dispense_sequence_duration_ms(a), b, dispense_sequence_duration_ms(b),
            );
        }
    }
}
