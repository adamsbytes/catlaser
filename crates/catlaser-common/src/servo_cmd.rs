//! [`ServoCommand`] packed struct and supporting types.
//!
//! Defines the 8-byte wire format sent from the compute module to the MCU
//! over UART at 200Hz. Both sides compile this crate, so the layout is
//! guaranteed identical at compile time.

use core::fmt;

use crate::constants::{PAN_HOME, SERVO_CMD_SIZE, TILT_HOME};

const _: () = assert!(
    core::mem::size_of::<ServoCommand>() == SERVO_CMD_SIZE,
    "ServoCommand must be exactly 8 bytes for UART wire format"
);

// ---------------------------------------------------------------------------
// ChecksumError
// ---------------------------------------------------------------------------

/// XOR checksum validation failure.
///
/// Returned by [`ServoCommand::from_bytes`] when byte 7 does not match
/// the XOR of bytes 0 through 6. The MCU discards the command and keeps
/// the last good one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("checksum mismatch: expected 0x{expected:02x}, got 0x{actual:02x}")]
pub struct ChecksumError {
    /// Computed checksum (XOR of bytes 0-6).
    pub expected: u8,
    /// Received checksum (byte 7).
    pub actual: u8,
}

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

/// Bitfield flags for [`ServoCommand`] (byte 6).
///
/// | Bit | Name             | Effect                                       |
/// |-----|------------------|----------------------------------------------|
/// | 0   | laser on         | Laser diode enable                           |
/// | 1   | person detected  | MCU tightens tilt limits                     |
/// | 2   | dispense left    | Deflector routes treats left                 |
/// | 3   | dispense right   | Deflector routes treats right                |
/// | 4-5 | dispense tier    | 0-2 index into MCU rotation table            |
/// | 6-7 | reserved         | Must be 0                                    |
#[derive(Clone, Copy, PartialEq, Eq, Default)]
#[must_use]
pub struct Flags(u8);

impl Flags {
    const LASER_ON: u8 = 0x01_u8;
    const PERSON_DETECTED: u8 = 0x02_u8;
    const DISPENSE_LEFT: u8 = 0x04_u8;
    const DISPENSE_RIGHT: u8 = 0x08_u8;
    const TIER_MASK: u8 = 0x30_u8;

    /// Creates flags with all bits cleared.
    pub const fn new() -> Self {
        Self(0_u8)
    }

    /// Creates flags from a raw byte value.
    pub const fn from_raw(raw: u8) -> Self {
        Self(raw)
    }

    /// Returns the raw byte value.
    pub const fn raw(self) -> u8 {
        self.0
    }

    /// Returns `true` if the laser enable bit is set.
    pub const fn laser_on(self) -> bool {
        self.0 & Self::LASER_ON != 0_u8
    }

    /// Returns `true` if the person-detected bit is set.
    pub const fn person_detected(self) -> bool {
        self.0 & Self::PERSON_DETECTED != 0_u8
    }

    /// Returns `true` if the dispense-left bit is set.
    pub const fn dispense_left(self) -> bool {
        self.0 & Self::DISPENSE_LEFT != 0_u8
    }

    /// Returns `true` if the dispense-right bit is set.
    pub const fn dispense_right(self) -> bool {
        self.0 & Self::DISPENSE_RIGHT != 0_u8
    }

    /// Returns the dispense tier (0-2, or 3 if the reserved value is set).
    pub const fn dispense_tier(self) -> u8 {
        (self.0 & Self::TIER_MASK) >> 4_u32
    }

    /// Sets or clears the laser enable bit.
    pub const fn with_laser(self, on: bool) -> Self {
        if on {
            Self(self.0 | Self::LASER_ON)
        } else {
            Self(self.0 & !Self::LASER_ON)
        }
    }

    /// Sets or clears the person-detected bit.
    pub const fn with_person_detected(self, detected: bool) -> Self {
        if detected {
            Self(self.0 | Self::PERSON_DETECTED)
        } else {
            Self(self.0 & !Self::PERSON_DETECTED)
        }
    }

    /// Sets or clears the dispense-left bit.
    pub const fn with_dispense_left(self, on: bool) -> Self {
        if on {
            Self(self.0 | Self::DISPENSE_LEFT)
        } else {
            Self(self.0 & !Self::DISPENSE_LEFT)
        }
    }

    /// Sets or clears the dispense-right bit.
    pub const fn with_dispense_right(self, on: bool) -> Self {
        if on {
            Self(self.0 | Self::DISPENSE_RIGHT)
        } else {
            Self(self.0 & !Self::DISPENSE_RIGHT)
        }
    }

    /// Sets the dispense tier (bits 4-5). Values above 3 are masked to 2 bits.
    pub const fn with_dispense_tier(self, tier: u8) -> Self {
        Self((self.0 & !Self::TIER_MASK) | ((tier & 0x03_u8) << 4_u32))
    }

    /// Returns the dispense direction if exactly one direction bit is set.
    ///
    /// - `dispense_left` only → `Some(Left)`
    /// - `dispense_right` only → `Some(Right)`
    /// - Neither or both set → `None`
    pub const fn dispense_direction(self) -> Option<DispenseDirection> {
        match (self.dispense_left(), self.dispense_right()) {
            (true, false) => Some(DispenseDirection::Left),
            (false, true) => Some(DispenseDirection::Right),
            (true, true) | (false, false) => None,
        }
    }
}

impl fmt::Debug for Flags {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Flags")
            .field("laser_on", &self.laser_on())
            .field("person_detected", &self.person_detected())
            .field("dispense_left", &self.dispense_left())
            .field("dispense_right", &self.dispense_right())
            .field("dispense_tier", &self.dispense_tier())
            .field("raw", &self.0)
            .finish()
    }
}

// ---------------------------------------------------------------------------
// DispenseDirection
// ---------------------------------------------------------------------------

/// Direction for treat dispensing via the deflector servo.
///
/// Derived from the dispense-left and dispense-right flag bits in
/// [`ServoCommand`]. Exactly one direction must be set for a valid
/// dispense request — setting both or neither returns `None` from
/// [`Flags::dispense_direction`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispenseDirection {
    /// Route treats to the left chute exit.
    Left,
    /// Route treats to the right chute exit.
    Right,
}

// ---------------------------------------------------------------------------
// ServoCommand
// ---------------------------------------------------------------------------

/// 8-byte packed command sent from compute module to MCU over UART.
///
/// # Wire format
///
/// | Offset | Size | Field      | Encoding                                |
/// |--------|------|------------|-----------------------------------------|
/// | 0      | 2    | pan        | i16 LE, degrees x 100                   |
/// | 2      | 2    | tilt       | i16 LE, degrees x 100                   |
/// | 4      | 1    | smoothing  | u8, 0-255 maps to 0.0-1.0              |
/// | 5      | 1    | max_slew   | u8, 0-255 deg/sec (0 = use default)     |
/// | 6      | 1    | flags      | bitfield, see [`Flags`]                 |
/// | 7      | 1    | checksum   | XOR of bytes 0-6                        |
#[derive(Clone, Copy, PartialEq, Eq)]
#[repr(C, packed)]
#[must_use]
pub struct ServoCommand {
    pan: i16,
    tilt: i16,
    smoothing: u8,
    max_slew: u8,
    flags: u8,
    checksum: u8,
}

impl ServoCommand {
    /// Command that parks servos at home position with laser off.
    ///
    /// Used by the MCU watchdog, power-down sequence, and initialization.
    pub const HOME: Self = Self::new(PAN_HOME, TILT_HOME, 255_u8, 0_u8, Flags::new());

    /// Creates a new command with the given parameters.
    ///
    /// The XOR checksum (byte 7) is computed automatically. Field values
    /// are not range-checked here -- the MCU clamps angles to configured
    /// limits on receipt.
    pub const fn new(pan: i16, tilt: i16, smoothing: u8, max_slew: u8, flags: Flags) -> Self {
        let [pan_lo, pan_hi] = pan.to_le_bytes();
        let [tilt_lo, tilt_hi] = tilt.to_le_bytes();
        let checksum = pan_lo ^ pan_hi ^ tilt_lo ^ tilt_hi ^ smoothing ^ max_slew ^ flags.raw();
        Self {
            pan,
            tilt,
            smoothing,
            max_slew,
            flags: flags.raw(),
            checksum,
        }
    }

    /// Serializes to the 8-byte wire format (little-endian).
    #[must_use]
    pub const fn to_bytes(self) -> [u8; SERVO_CMD_SIZE] {
        let [pan_lo, pan_hi] = self.pan.to_le_bytes();
        let [tilt_lo, tilt_hi] = self.tilt.to_le_bytes();
        [
            pan_lo,
            pan_hi,
            tilt_lo,
            tilt_hi,
            self.smoothing,
            self.max_slew,
            self.flags,
            self.checksum,
        ]
    }

    /// Deserializes from the 8-byte wire format.
    ///
    /// Returns [`ChecksumError`] if byte 7 does not match the XOR of
    /// bytes 0 through 6.
    pub const fn from_bytes(bytes: [u8; SERVO_CMD_SIZE]) -> Result<Self, ChecksumError> {
        let [b0, b1, b2, b3, b4, b5, b6, b7] = bytes;
        let expected = b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6;
        if expected != b7 {
            return Err(ChecksumError {
                expected,
                actual: b7,
            });
        }
        Ok(Self {
            pan: i16::from_le_bytes([b0, b1]),
            tilt: i16::from_le_bytes([b2, b3]),
            smoothing: b4,
            max_slew: b5,
            flags: b6,
            checksum: b7,
        })
    }

    /// Returns `true` if the stored checksum matches the computed checksum.
    #[must_use]
    pub const fn verify_checksum(self) -> bool {
        let [b0, b1, b2, b3, b4, b5, b6, b7] = self.to_bytes();
        b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6 == b7
    }

    /// Target pan angle in hundredths of a degree.
    pub const fn pan(self) -> i16 {
        self.pan
    }

    /// Target tilt angle in hundredths of a degree.
    pub const fn tilt(self) -> i16 {
        self.tilt
    }

    /// Interpolation smoothing factor (0-255 maps to 0.0-1.0).
    pub const fn smoothing(self) -> u8 {
        self.smoothing
    }

    /// Maximum slew rate (0-255 maps to deg/sec, 0 = use default).
    pub const fn max_slew(self) -> u8 {
        self.max_slew
    }

    /// Command flags (laser, person-detected, dispense control).
    pub const fn flags(self) -> Flags {
        Flags(self.flags)
    }
}

impl fmt::Debug for ServoCommand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let checksum = self.checksum;
        f.debug_struct("ServoCommand")
            .field("pan", &self.pan())
            .field("tilt", &self.tilt())
            .field("smoothing", &self.smoothing())
            .field("max_slew", &self.max_slew())
            .field("flags", &self.flags())
            .field("checksum", &checksum)
            .finish()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::{PAN_HOME, SERVO_CMD_SIZE, TILT_HOME};
    use proptest::prelude::*;

    #[test]
    fn test_servo_command_size_is_8_bytes() {
        assert_eq!(
            core::mem::size_of::<ServoCommand>(),
            SERVO_CMD_SIZE,
            "ServoCommand must be exactly 8 bytes for UART wire format"
        );
    }

    #[test]
    fn test_new_fields_round_trip() {
        let flags = Flags::new().with_laser(true).with_dispense_tier(2_u8);
        let cmd = ServoCommand::new(4523_i16, -1000_i16, 128_u8, 200_u8, flags);

        assert_eq!(cmd.pan(), 4523_i16, "pan field mismatch");
        assert_eq!(cmd.tilt(), -1000_i16, "tilt field mismatch");
        assert_eq!(cmd.smoothing(), 128_u8, "smoothing field mismatch");
        assert_eq!(cmd.max_slew(), 200_u8, "max_slew field mismatch");
        assert_eq!(cmd.flags(), flags, "flags field mismatch");
    }

    #[test]
    fn test_checksum_computed_correctly() {
        // pan=4523 (0x11AB LE: [0xAB, 0x11]), tilt=-1000 (0xFC18 LE: [0x18, 0xFC]),
        // smoothing=128 (0x80), max_slew=200 (0xC8), flags=0x05
        // XOR: 0xAB ^ 0x11 ^ 0x18 ^ 0xFC ^ 0x80 ^ 0xC8 ^ 0x05 = 0x13
        let flags = Flags::from_raw(0x05_u8);
        let cmd = ServoCommand::new(4523_i16, -1000_i16, 128_u8, 200_u8, flags);
        let [_, _, _, _, _, _, _, checksum] = cmd.to_bytes();

        assert_eq!(
            checksum, 0x13_u8,
            "checksum does not match hand-computed XOR"
        );
    }

    #[test]
    fn test_to_bytes_from_bytes_round_trip() {
        let flags = Flags::new()
            .with_laser(true)
            .with_person_detected(true)
            .with_dispense_tier(1_u8);
        let original = ServoCommand::new(-4500_i16, 3000_i16, 64_u8, 150_u8, flags);
        let bytes = original.to_bytes();
        let recovered = ServoCommand::from_bytes(bytes);

        assert_eq!(recovered, Ok(original), "round-trip through bytes failed");
    }

    #[test]
    fn test_from_bytes_corrupted_byte_returns_error() {
        let cmd = ServoCommand::new(
            4523_i16,
            -1000_i16,
            128_u8,
            200_u8,
            Flags::from_raw(0x05_u8),
        );
        let [b0, b1, b2, b3, b4, b5, b6, b7] = cmd.to_bytes();

        assert!(
            ServoCommand::from_bytes([b0 ^ 0xFF_u8, b1, b2, b3, b4, b5, b6, b7]).is_err(),
            "pan lo corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1 ^ 0xFF_u8, b2, b3, b4, b5, b6, b7]).is_err(),
            "pan hi corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2 ^ 0xFF_u8, b3, b4, b5, b6, b7]).is_err(),
            "tilt lo corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2, b3 ^ 0xFF_u8, b4, b5, b6, b7]).is_err(),
            "tilt hi corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2, b3, b4 ^ 0xFF_u8, b5, b6, b7]).is_err(),
            "smoothing corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2, b3, b4, b5 ^ 0xFF_u8, b6, b7]).is_err(),
            "max_slew corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2, b3, b4, b5, b6 ^ 0xFF_u8, b7]).is_err(),
            "flags corruption not detected"
        );
        assert!(
            ServoCommand::from_bytes([b0, b1, b2, b3, b4, b5, b6, b7 ^ 0xFF_u8]).is_err(),
            "checksum corruption not detected"
        );
    }

    #[test]
    fn test_home_command_valid() {
        let home = ServoCommand::HOME;
        assert_eq!(home.pan(), PAN_HOME, "HOME pan should be PAN_HOME");
        assert_eq!(home.tilt(), TILT_HOME, "HOME tilt should be TILT_HOME");
        assert_eq!(
            home.smoothing(),
            255_u8,
            "HOME smoothing should be 255 (snap to target)"
        );
        assert_eq!(home.max_slew(), 0_u8, "HOME max_slew should be 0");
        assert!(home.verify_checksum(), "HOME checksum must be valid");
    }

    #[test]
    fn test_home_command_laser_off() {
        assert!(
            !ServoCommand::HOME.flags().laser_on(),
            "HOME must have laser off"
        );
    }

    #[test]
    fn test_boundary_values_max_angles() {
        let cmd = ServoCommand::new(
            i16::MIN,
            i16::MAX,
            u8::MAX,
            u8::MAX,
            Flags::from_raw(u8::MAX),
        );
        let bytes = cmd.to_bytes();
        let recovered = ServoCommand::from_bytes(bytes);

        assert_eq!(recovered, Ok(cmd), "extreme values must survive round-trip");
    }

    // --- Flags tests ---

    #[test]
    fn test_flags_default_is_zero() {
        assert_eq!(Flags::default().raw(), 0_u8, "default flags must be zero");
    }

    #[test]
    fn test_flags_laser_on_isolation() {
        let flags = Flags::new().with_laser(true);
        assert!(flags.laser_on(), "laser_on bit not set");
        assert!(
            !flags.person_detected(),
            "person_detected should not be set"
        );
        assert!(!flags.dispense_left(), "dispense_left should not be set");
        assert!(!flags.dispense_right(), "dispense_right should not be set");
        assert_eq!(flags.dispense_tier(), 0_u8, "dispense_tier should be 0");
    }

    #[test]
    fn test_flags_person_detected_isolation() {
        let flags = Flags::new().with_person_detected(true);
        assert!(!flags.laser_on(), "laser_on should not be set");
        assert!(flags.person_detected(), "person_detected bit not set");
        assert!(!flags.dispense_left(), "dispense_left should not be set");
        assert!(!flags.dispense_right(), "dispense_right should not be set");
        assert_eq!(flags.dispense_tier(), 0_u8, "dispense_tier should be 0");
    }

    #[test]
    fn test_flags_dispense_left_isolation() {
        let flags = Flags::new().with_dispense_left(true);
        assert!(!flags.laser_on(), "laser_on should not be set");
        assert!(
            !flags.person_detected(),
            "person_detected should not be set"
        );
        assert!(flags.dispense_left(), "dispense_left bit not set");
        assert!(!flags.dispense_right(), "dispense_right should not be set");
        assert_eq!(flags.dispense_tier(), 0_u8, "dispense_tier should be 0");
    }

    #[test]
    fn test_flags_dispense_right_isolation() {
        let flags = Flags::new().with_dispense_right(true);
        assert!(!flags.laser_on(), "laser_on should not be set");
        assert!(
            !flags.person_detected(),
            "person_detected should not be set"
        );
        assert!(!flags.dispense_left(), "dispense_left should not be set");
        assert!(flags.dispense_right(), "dispense_right bit not set");
        assert_eq!(flags.dispense_tier(), 0_u8, "dispense_tier should be 0");
    }

    #[test]
    fn test_flags_dispense_tier_round_trip() {
        for tier in 0_u8..=2_u8 {
            let flags = Flags::new().with_dispense_tier(tier);
            assert_eq!(
                flags.dispense_tier(),
                tier,
                "tier {tier} did not round-trip"
            );
        }
    }

    #[test]
    fn test_flags_reserved_tier_3_round_trip() {
        let flags = Flags::new().with_dispense_tier(3_u8);
        assert_eq!(
            flags.dispense_tier(),
            3_u8,
            "reserved tier 3 did not round-trip"
        );
    }

    #[test]
    fn test_flags_combined_all_set() {
        let flags = Flags::new()
            .with_laser(true)
            .with_person_detected(true)
            .with_dispense_left(true)
            .with_dispense_right(true)
            .with_dispense_tier(2_u8);

        assert!(flags.laser_on(), "laser_on should be set");
        assert!(flags.person_detected(), "person_detected should be set");
        assert!(flags.dispense_left(), "dispense_left should be set");
        assert!(flags.dispense_right(), "dispense_right should be set");
        assert_eq!(flags.dispense_tier(), 2_u8, "dispense_tier should be 2");
    }

    #[test]
    fn test_flags_with_laser_false_clears_bit() {
        let flags = Flags::new().with_laser(true).with_laser(false);
        assert!(
            !flags.laser_on(),
            "laser_on should be cleared after with_laser(false)"
        );
    }

    // --- DispenseDirection tests ---

    #[test]
    fn test_dispense_direction_left_only() {
        let flags = Flags::new().with_dispense_left(true);
        assert_eq!(
            flags.dispense_direction(),
            Some(DispenseDirection::Left),
            "left-only must return Left"
        );
    }

    #[test]
    fn test_dispense_direction_right_only() {
        let flags = Flags::new().with_dispense_right(true);
        assert_eq!(
            flags.dispense_direction(),
            Some(DispenseDirection::Right),
            "right-only must return Right"
        );
    }

    #[test]
    fn test_dispense_direction_neither() {
        let flags = Flags::new();
        assert_eq!(
            flags.dispense_direction(),
            None,
            "neither direction must return None"
        );
    }

    #[test]
    fn test_dispense_direction_both_invalid() {
        let flags = Flags::new()
            .with_dispense_left(true)
            .with_dispense_right(true);
        assert_eq!(
            flags.dispense_direction(),
            None,
            "both directions set must return None"
        );
    }

    #[test]
    fn test_dispense_direction_independent_of_other_flags() {
        let flags = Flags::new()
            .with_laser(true)
            .with_person_detected(true)
            .with_dispense_left(true)
            .with_dispense_tier(2_u8);
        assert_eq!(
            flags.dispense_direction(),
            Some(DispenseDirection::Left),
            "direction must be independent of other flags"
        );
    }

    // --- Proptest ---

    proptest! {
        #[test]
        fn test_dispense_direction_consistent_with_accessors(
            flags_raw in any::<u8>(),
        ) {
            let flags = Flags::from_raw(flags_raw);
            let direction = flags.dispense_direction();
            match (flags.dispense_left(), flags.dispense_right()) {
                (true, false) => prop_assert_eq!(direction, Some(DispenseDirection::Left)),
                (false, true) => prop_assert_eq!(direction, Some(DispenseDirection::Right)),
                (true, true) | (false, false) => prop_assert_eq!(direction, None),
            }
        }

        #[test]
        fn test_arbitrary_command_round_trips(
            pan in any::<i16>(),
            tilt in any::<i16>(),
            smoothing in any::<u8>(),
            max_slew in any::<u8>(),
            flags_raw in any::<u8>(),
        ) {
            let cmd = ServoCommand::new(pan, tilt, smoothing, max_slew, Flags::from_raw(flags_raw));
            let bytes = cmd.to_bytes();
            let recovered = ServoCommand::from_bytes(bytes);
            prop_assert_eq!(recovered, Ok(cmd));
        }

        #[test]
        fn test_arbitrary_bytes_bad_checksum_rejected(
            b0 in any::<u8>(),
            b1 in any::<u8>(),
            b2 in any::<u8>(),
            b3 in any::<u8>(),
            b4 in any::<u8>(),
            b5 in any::<u8>(),
            b6 in any::<u8>(),
        ) {
            let correct = b0 ^ b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6;
            let wrong = correct ^ 0x01_u8;
            prop_assert!(ServoCommand::from_bytes([b0, b1, b2, b3, b4, b5, b6, wrong]).is_err());
        }
    }
}
