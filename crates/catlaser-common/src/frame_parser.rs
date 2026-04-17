//! Byte-stream frame parser for [`ServoCommand`] UART protocol.
//!
//! The compute module sends 8-byte [`ServoCommand`] frames over UART. This
//! parser accepts bytes one at a time and emits valid commands as they are
//! found, automatically resyncing on checksum failures by sliding the window
//! forward one byte.

use crate::ServoCommand;
use crate::constants::SERVO_CMD_SIZE;

/// Frame size as `u8` for internal counter arithmetic.
///
/// `SERVO_CMD_SIZE` is a compile-time constant (8). The `assert!` inside
/// validates it fits in `u8` before the truncating cast.
const FRAME_LEN: u8 = {
    assert!(
        SERVO_CMD_SIZE <= 255_usize,
        "SERVO_CMD_SIZE must fit in u8 for FrameParser internals"
    );
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "SERVO_CMD_SIZE is 8, validated by the assert above"
    )]
    {
        SERVO_CMD_SIZE as u8
    }
};

/// Sliding-window parser that extracts [`ServoCommand`] frames from a byte stream.
///
/// Accumulates bytes until a full 8-byte frame is present, then validates the
/// XOR checksum. On checksum failure (lost sync), the parser drops the oldest
/// byte and continues accumulating — no external intervention needed.
///
/// # Usage
///
/// ```
/// # use catlaser_common::{FrameParser, ServoCommand, Flags};
/// let mut parser = FrameParser::new();
/// let cmd = ServoCommand::new(4500, -1000, 128, 200, Flags::new().with_laser(true));
/// let bytes = cmd.to_bytes();
///
/// for &b in &bytes[..7] {
///     assert!(parser.push(b).is_none());
/// }
/// assert_eq!(parser.push(bytes[7]), Some(cmd));
/// ```
#[derive(Debug)]
pub struct FrameParser {
    buf: [u8; SERVO_CMD_SIZE],
    len: u8,
}

impl FrameParser {
    /// Creates a new parser with an empty buffer.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            buf: [0_u8; SERVO_CMD_SIZE],
            len: 0_u8,
        }
    }

    /// Feeds one byte into the parser.
    ///
    /// Returns `Some(cmd)` when a complete frame with a valid checksum is
    /// found. Returns `None` while accumulating bytes or after discarding a
    /// bad frame.
    ///
    /// On checksum failure the parser shifts the internal buffer left by one
    /// byte (dropping the oldest) and continues accumulating. This allows
    /// resynchronisation after noise or partial frames without external logic.
    pub fn push(&mut self, byte: u8) -> Option<ServoCommand> {
        let pos = usize::from(self.len);

        // `self.len` is always in 0..FRAME_LEN at this point:
        //   - Starts at 0 (new / reset)
        //   - After successful parse: reset to 0
        //   - After failed parse: reset to FRAME_LEN - 1 (7)
        // So `pos` is 0..=7, valid for a [u8; 8] array. The `.get_mut()`
        // check is a defensive belt — it cannot return None in practice.
        let slot = self.buf.get_mut(pos)?;
        *slot = byte;
        self.len = self.len.saturating_add(1_u8);

        if self.len < FRAME_LEN {
            return None;
        }

        if let Ok(cmd) = ServoCommand::from_bytes(self.buf) {
            self.len = 0_u8;
            Some(cmd)
        } else {
            // Checksum mismatch — drop oldest byte, shift left by one.
            self.buf.copy_within(1_usize..SERVO_CMD_SIZE, 0_usize);
            self.len = FRAME_LEN.saturating_sub(1_u8);
            None
        }
    }

    /// Resets the parser, discarding any partially accumulated bytes.
    pub const fn reset(&mut self) {
        self.len = 0_u8;
    }

    /// Number of bytes currently buffered.
    #[must_use]
    pub const fn buffered(&self) -> u8 {
        self.len
    }
}

impl Default for FrameParser {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Flags;
    use proptest::prelude::*;

    /// Push every byte of a serialized command through the parser, returning
    /// whatever the parser emits on the last byte.
    fn push_command(parser: &mut FrameParser, cmd: ServoCommand) -> Option<ServoCommand> {
        let bytes = cmd.to_bytes();
        let mut result = None;
        for &b in &bytes {
            if let Some(c) = parser.push(b) {
                result = Some(c);
            }
        }
        result
    }

    // --- Basic parsing ---

    #[test]
    fn test_parse_valid_frame_exact_boundary() {
        let mut parser = FrameParser::new();
        let cmd = ServoCommand::new(
            4523_i16,
            -1000_i16,
            128_u8,
            200_u8,
            Flags::new().with_laser(true),
        );

        let result = push_command(&mut parser, cmd);
        assert_eq!(
            result,
            Some(cmd),
            "valid frame must parse at exact 8-byte boundary"
        );
    }

    #[test]
    fn test_parse_back_to_back_frames() {
        let mut parser = FrameParser::new();
        let cmd_a = ServoCommand::new(1000_i16, 2000_i16, 64_u8, 100_u8, Flags::new());
        let cmd_b = ServoCommand::new(
            -3000_i16,
            500_i16,
            200_u8,
            50_u8,
            Flags::new().with_dispense_left(true),
        );

        let result_a = push_command(&mut parser, cmd_a);
        assert_eq!(result_a, Some(cmd_a), "first frame must parse");

        let result_b = push_command(&mut parser, cmd_b);
        assert_eq!(
            result_b,
            Some(cmd_b),
            "second frame must parse immediately after first"
        );
    }

    #[test]
    fn test_parse_insufficient_bytes_returns_none() {
        let mut parser = FrameParser::new();
        let cmd = ServoCommand::new(0_i16, 0_i16, 0_u8, 0_u8, Flags::new());
        let bytes = cmd.to_bytes();

        // Feed 7 of 8 bytes — must not produce a command.
        for &b in bytes.iter().take(7_usize) {
            assert!(
                parser.push(b).is_none(),
                "must not parse with fewer than 8 bytes"
            );
        }
    }

    #[test]
    fn test_home_command_round_trips() {
        let mut parser = FrameParser::new();
        let result = push_command(&mut parser, ServoCommand::HOME);
        assert_eq!(
            result,
            Some(ServoCommand::HOME),
            "HOME command must round-trip through parser"
        );
    }

    #[test]
    fn test_boundary_values_parse() {
        let mut parser = FrameParser::new();
        let cmd = ServoCommand::new(
            i16::MIN,
            i16::MAX,
            u8::MAX,
            u8::MAX,
            Flags::from_raw(0x3F_u8),
        );

        let result = push_command(&mut parser, cmd);
        assert_eq!(result, Some(cmd), "extreme field values must parse");
    }

    // --- Resynchronisation ---

    #[test]
    fn test_parse_corrupted_byte_resyncs() {
        let mut parser = FrameParser::new();

        // Send a frame with byte 0 corrupted — checksum will fail.
        let cmd = ServoCommand::new(4523_i16, -1000_i16, 128_u8, 200_u8, Flags::new());
        let [b0, b1, b2, b3, b4, b5, b6, b7] = cmd.to_bytes();
        let bad_frame = [b0 ^ 0xFF_u8, b1, b2, b3, b4, b5, b6, b7];

        for &b in &bad_frame {
            assert!(parser.push(b).is_none(), "corrupted frame must not parse");
        }

        // Parser shifted buffer left (7 bytes remain). A valid frame must
        // eventually resync.
        let good_cmd = ServoCommand::new(100_i16, 200_i16, 50_u8, 75_u8, Flags::new());
        let result = push_command(&mut parser, good_cmd);
        assert_eq!(
            result,
            Some(good_cmd),
            "must resync and parse valid frame after corruption"
        );
    }

    #[test]
    fn test_parse_single_garbage_byte_then_valid() {
        let mut parser = FrameParser::new();

        assert!(
            parser.push(0xDE_u8).is_none(),
            "garbage byte must not parse"
        );

        let cmd = ServoCommand::new(0_i16, 4500_i16, 255_u8, 0_u8, Flags::new().with_laser(true));
        let result = push_command(&mut parser, cmd);
        assert_eq!(
            result,
            Some(cmd),
            "valid frame after single garbage byte must parse"
        );
    }

    #[test]
    fn test_parse_many_garbage_bytes_then_valid() {
        let mut parser = FrameParser::new();

        for i in 0_u8..50_u8 {
            parser.push(i);
        }

        let cmd = ServoCommand::new(-9000_i16, 9000_i16, 128_u8, 128_u8, Flags::new());
        let result = push_command(&mut parser, cmd);
        assert_eq!(
            result,
            Some(cmd),
            "valid frame after many garbage bytes must parse"
        );
    }

    // --- Reset ---

    #[test]
    fn test_reset_clears_partial_state() {
        let mut parser = FrameParser::new();

        for _ in 0_u8..4_u8 {
            parser.push(0xAA_u8);
        }
        assert_eq!(parser.buffered(), 4_u8, "should have 4 bytes buffered");

        parser.reset();
        assert_eq!(parser.buffered(), 0_u8, "reset must clear buffered count");

        let cmd = ServoCommand::new(1000_i16, 2000_i16, 64_u8, 100_u8, Flags::new());
        let result = push_command(&mut parser, cmd);
        assert_eq!(result, Some(cmd), "valid frame after reset must parse");
    }

    #[test]
    fn test_default_matches_new() {
        let from_new = FrameParser::new();
        let from_default = FrameParser::default();
        assert_eq!(
            from_new.buffered(),
            from_default.buffered(),
            "default() and new() must produce identical state"
        );
    }

    // --- Property tests ---

    proptest! {
        #[test]
        fn test_arbitrary_valid_command_parses(
            pan in any::<i16>(),
            tilt in any::<i16>(),
            smoothing in any::<u8>(),
            max_slew in any::<u8>(),
            flags_raw in any::<u8>(),
        ) {
            let cmd = ServoCommand::new(pan, tilt, smoothing, max_slew, Flags::from_raw(flags_raw));
            let mut parser = FrameParser::new();
            let result = push_command(&mut parser, cmd);
            prop_assert_eq!(result, Some(cmd), "any valid command must parse on a fresh parser");
        }

        #[test]
        fn test_two_arbitrary_commands_back_to_back(
            pan_a in any::<i16>(),
            tilt_a in any::<i16>(),
            smooth_a in any::<u8>(),
            slew_a in any::<u8>(),
            flags_a in any::<u8>(),
            pan_b in any::<i16>(),
            tilt_b in any::<i16>(),
            smooth_b in any::<u8>(),
            slew_b in any::<u8>(),
            flags_b in any::<u8>(),
        ) {
            let cmd_a = ServoCommand::new(pan_a, tilt_a, smooth_a, slew_a, Flags::from_raw(flags_a));
            let cmd_b = ServoCommand::new(pan_b, tilt_b, smooth_b, slew_b, Flags::from_raw(flags_b));
            let mut parser = FrameParser::new();

            let result_a = push_command(&mut parser, cmd_a);
            prop_assert_eq!(result_a, Some(cmd_a), "first command must parse");

            let result_b = push_command(&mut parser, cmd_b);
            prop_assert_eq!(result_b, Some(cmd_b), "second command must parse");
        }

        #[test]
        fn test_parser_buffered_count_never_exceeds_frame_size(
            bytes in proptest::collection::vec(any::<u8>(), 0..=256),
        ) {
            let mut parser = FrameParser::new();
            for &b in &bytes {
                parser.push(b);
                prop_assert!(
                    parser.buffered() < FRAME_LEN,
                    "buffered count {} must be less than frame size {}",
                    parser.buffered(),
                    FRAME_LEN,
                );
            }
        }
    }
}
