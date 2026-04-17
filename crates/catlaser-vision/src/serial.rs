//! [`ServoCommand`] packing and UART transmission to the MCU.
//!
//! Assembles 8-byte [`ServoCommand`] frames from [`TargetingSolution`] and
//! [`SafetyResult`] state, then transmits them over UART to the RP2040 MCU
//! at 115200 baud, 8-N-1.
//!
//! The packing logic is pure: [`build_command`] translates targeting angles
//! and safety flags into a checksummed wire-format struct. The transport
//! layer ([`SerialPort`]) handles device open, termios configuration, and
//! byte-level writes. The MCU's [`FrameParser`](catlaser_common::FrameParser)
//! consumes the stream on the other end.
//!
//! All unsafe code in this module is covered by ADR-003.

use std::io::{self, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::Path;

use catlaser_common::constants::{SERVO_CMD_SIZE, UART_BAUD};
use catlaser_common::{DispenseDirection, Flags, ServoCommand};

use crate::targeting::TargetingSolution;

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Errors from serial port operations.
#[derive(Debug, thiserror::Error)]
pub(crate) enum SerialError {
    /// Failed to open the UART device node.
    #[error("failed to open UART device {path}: {source}")]
    Open {
        /// Device path that was attempted.
        path: String,
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to get or set termios attributes.
    #[error("termios configuration failed on {path}: {source}")]
    Termios {
        /// Device path.
        path: String,
        /// Underlying OS error.
        source: io::Error,
    },

    /// Failed to write command bytes to the UART.
    #[error("UART write failed: {0}")]
    Write(io::Error),

    /// Repeated writes produced zero bytes — the device is gone.
    #[error("UART write stalled after {sent} of {SERVO_CMD_SIZE} bytes")]
    WriteStall {
        /// Number of bytes written before the stall.
        sent: usize,
    },
}

// ---------------------------------------------------------------------------
// Command assembly
// ---------------------------------------------------------------------------

/// Parameters from the behavior engine that aren't computed by targeting
/// or safety — carried through from `BehaviorCommand` over IPC.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CommandParams {
    /// Whether the laser diode should be enabled.
    pub laser_on: bool,
    /// Interpolation smoothing factor (0-255 maps to 0.0-1.0).
    pub smoothing: u8,
    /// Maximum slew rate (0-255 deg/sec, 0 = use default).
    pub max_slew: u8,
    /// Dispense request, if any. `None` during normal tracking.
    pub dispense: Option<DispenseRequest>,
}

/// A request to dispense treats via the deflector and disc servos.
#[derive(Debug, Clone, Copy)]
pub(crate) struct DispenseRequest {
    /// Which chute exit to route treats to.
    pub direction: DispenseDirection,
    /// Engagement tier (0-2) indexing into the MCU's rotation table.
    pub tier: u8,
}

/// Assembles a [`ServoCommand`] from targeting output and behavior
/// parameters.
///
/// This is a pure function — no I/O, no state. The resulting command has
/// a valid XOR checksum and is ready for UART transmission.
///
/// The flags byte is wired as follows:
/// - `laser_on`: from `params.laser_on`
/// - dispense direction + tier: from `params.dispense` if present
///
/// No safety input crosses the UART. The MCU's Secure world enforces
/// eye safety from hardware observables it owns (watchdog + dwell
/// monitor on the PWM compare registers) plus the Class 2 power
/// ceiling, so the compute module cannot influence the laser-gating
/// decision by construction.
pub(crate) fn build_command(solution: TargetingSolution, params: CommandParams) -> ServoCommand {
    let mut flags = Flags::new().with_laser(params.laser_on);

    if let Some(dispense) = params.dispense {
        flags = match dispense.direction {
            DispenseDirection::Left => flags.with_dispense_left(true),
            DispenseDirection::Right => flags.with_dispense_right(true),
        };
        flags = flags.with_dispense_tier(dispense.tier);
    }

    ServoCommand::new(
        solution.pan,
        solution.tilt,
        params.smoothing,
        params.max_slew,
        flags,
    )
}

// ---------------------------------------------------------------------------
// UART transport
// ---------------------------------------------------------------------------

/// UART serial port for transmitting [`ServoCommand`] frames to the MCU.
///
/// Owns an [`OwnedFd`] to the configured UART device. The device is
/// opened in blocking mode with raw termios (no line discipline, no echo,
/// no signal generation) at [`UART_BAUD`] baud, 8-N-1.
#[derive(Debug)]
pub(crate) struct SerialPort {
    fd: OwnedFd,
}

impl SerialPort {
    /// Opens and configures a UART device for servo command transmission.
    ///
    /// `path` is the device node (e.g. `/dev/ttyS3` on the RV1106G3).
    /// The device is configured for raw 8-N-1 at 115200 baud with no
    /// flow control.
    pub(crate) fn open(path: &Path) -> Result<Self, SerialError> {
        let fd = open_uart(path)?;
        configure_termios(&fd, path)?;
        Ok(Self { fd })
    }

    /// Packs and transmits a single [`ServoCommand`] over UART.
    ///
    /// Serializes the command to its 8-byte wire format and writes all
    /// bytes, retrying on partial writes (e.g. signal interruption during
    /// the ~694 us transfer at 115200 baud). Returns
    /// [`SerialError::WriteStall`] if a write returns zero bytes, which
    /// indicates the device is no longer accepting data.
    pub(crate) fn send(&self, cmd: ServoCommand) -> Result<(), SerialError> {
        let bytes = cmd.to_bytes();
        write_all_fd(&self.fd, &bytes)
    }
}

// ---------------------------------------------------------------------------
// OS helpers
// ---------------------------------------------------------------------------

/// Opens a UART device node with `O_RDWR | O_NOCTTY`.
///
/// `O_NOCTTY` prevents the device from becoming the controlling terminal.
/// Blocking mode is used because servo commands are time-critical and the
/// write buffer is only 8 bytes — it completes immediately at 115200 baud.
fn open_uart(path: &Path) -> Result<OwnedFd, SerialError> {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY)
        .open(path)
        .map_err(|source| SerialError::Open {
            path: path.display().to_string(),
            source,
        })?;

    Ok(OwnedFd::from(file))
}

/// Configures raw 8-N-1 termios at [`UART_BAUD`] baud on the given fd.
fn configure_termios(fd: &OwnedFd, path: &Path) -> Result<(), SerialError> {
    let raw_fd = fd.as_raw_fd();
    let path_str = path.display().to_string();

    let mut termios = std::mem::MaybeUninit::<libc::termios>::zeroed();

    #[expect(
        unsafe_code,
        reason = "libc::tcgetattr reads termios from a valid fd — ADR-003"
    )]
    // SAFETY: raw_fd is a valid open file descriptor from OpenOptions::open().
    // termios is a properly aligned, zeroed MaybeUninit<termios> on the stack.
    let ret = unsafe { libc::tcgetattr(raw_fd, termios.as_mut_ptr()) };

    if ret != 0_i32 {
        return Err(SerialError::Termios {
            path: path_str,
            source: io::Error::last_os_error(),
        });
    }

    #[expect(
        unsafe_code,
        reason = "tcgetattr succeeded, so termios is now initialized — ADR-003"
    )]
    // SAFETY: tcgetattr returned 0, meaning it fully initialized the struct.
    let mut termios = unsafe { termios.assume_init() };

    // Raw mode: no input processing, no output processing, no echo,
    // no signal generation, no canonical mode.
    termios.c_iflag &= !(libc::IGNBRK
        | libc::BRKINT
        | libc::PARMRK
        | libc::ISTRIP
        | libc::INLCR
        | libc::IGNCR
        | libc::ICRNL
        | libc::IXON);
    termios.c_oflag &= !libc::OPOST;
    termios.c_lflag &= !(libc::ECHO | libc::ECHONL | libc::ICANON | libc::ISIG | libc::IEXTEN);
    termios.c_cflag &= !(libc::CSIZE | libc::PARENB);
    termios.c_cflag |= libc::CS8 | libc::CLOCAL | libc::CREAD;

    // Baud rate.
    let baud = baud_to_speed(UART_BAUD);

    #[expect(
        unsafe_code,
        reason = "libc::cfsetispeed on a valid termios struct — ADR-003"
    )]
    // SAFETY: termios is a valid, initialized termios struct. baud is a
    // valid libc speed constant.
    let ret = unsafe { libc::cfsetispeed(std::ptr::from_mut(&mut termios), baud) };
    if ret != 0_i32 {
        return Err(SerialError::Termios {
            path: path_str,
            source: io::Error::last_os_error(),
        });
    }

    #[expect(
        unsafe_code,
        reason = "libc::cfsetospeed on a valid termios struct — ADR-003"
    )]
    // SAFETY: same as cfsetispeed above.
    let ret = unsafe { libc::cfsetospeed(std::ptr::from_mut(&mut termios), baud) };
    if ret != 0_i32 {
        return Err(SerialError::Termios {
            path: path_str,
            source: io::Error::last_os_error(),
        });
    }

    // VMIN=0, VTIME=0: non-blocking read semantics (we only write, but
    // this prevents reads from hanging if the fd is ever read).
    termios.c_cc[libc::VMIN] = 0_u8;
    termios.c_cc[libc::VTIME] = 0_u8;

    #[expect(
        unsafe_code,
        reason = "libc::tcsetattr applies termios to a valid fd — ADR-003"
    )]
    // SAFETY: raw_fd is valid. termios is fully configured. TCSANOW
    // applies immediately.
    let ret = unsafe { libc::tcsetattr(raw_fd, libc::TCSANOW, std::ptr::from_ref(&termios)) };
    if ret != 0_i32 {
        return Err(SerialError::Termios {
            path: path_str,
            source: io::Error::last_os_error(),
        });
    }

    Ok(())
}

/// Maps a numeric baud rate to the corresponding `libc::speed_t` constant.
///
/// Only 115200 is used in this project, but the function is explicit about
/// what it supports rather than silently passing through raw values.
const fn baud_to_speed(baud: u32) -> libc::speed_t {
    match baud {
        115_200_u32 => libc::B115200,
        #[expect(
            clippy::match_same_arms,
            reason = "explicit fallback documents that only 115200 is supported; \
                      other rates intentionally map to the same default"
        )]
        _ => libc::B115200,
    }
}

/// Writes the entire buffer to a file descriptor, retrying on partial writes.
///
/// A single `libc::write` for 8 bytes on a blocking UART completes
/// atomically in practice, but a signal delivered during the transfer
/// can cause a short write or an `EINTR`. This loop retries both cases
/// until all bytes are sent. Returns [`SerialError::WriteStall`] if a
/// write returns zero bytes (device gone / broken pipe).
fn write_all_fd(fd: &OwnedFd, buf: &[u8]) -> Result<(), SerialError> {
    let mut writer = fd_to_write(fd);
    let mut sent = 0_usize;
    while sent < buf.len() {
        match writer.write(buf.get(sent..).unwrap_or_default()) {
            Ok(0_usize) => return Err(SerialError::WriteStall { sent }),
            Ok(n) => sent = sent.saturating_add(n),
            // Signal interrupted the write before any bytes transferred.
            // Retry at the same offset — standard POSIX pattern.
            Err(err) if err.raw_os_error() == Some(libc::EINTR) => {}
            Err(err) => return Err(SerialError::Write(err)),
        }
    }
    Ok(())
}

/// Borrows an `OwnedFd` as a writable `std::fs::File` reference without
/// taking ownership.
///
/// Wraps the raw fd in a thin [`Write`] adapter that calls `libc::write`
/// directly.
fn fd_to_write(fd: &OwnedFd) -> impl Write + '_ {
    struct FdWriter<'a>(&'a OwnedFd);

    impl Write for FdWriter<'_> {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            #[expect(
                unsafe_code,
                reason = "libc::write on a valid fd with a valid buffer — ADR-003"
            )]
            // SAFETY: self.0 is a valid open fd. buf.as_ptr() is valid for
            // buf.len() bytes. libc::write returns the number of bytes
            // written or -1 on error.
            let ret = unsafe { libc::write(self.0.as_raw_fd(), buf.as_ptr().cast(), buf.len()) };
            if ret < 0_isize {
                Err(io::Error::last_os_error())
            } else {
                #[expect(
                    clippy::as_conversions,
                    clippy::cast_sign_loss,
                    reason = "ret >= 0 checked above; isize-to-usize is lossless when non-negative"
                )]
                Ok(ret as usize)
            }
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    FdWriter(fd)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use catlaser_common::constants::{PAN_HOME, TILT_HOME};
    use proptest::prelude::*;

    // --- Helpers ---

    fn default_params() -> CommandParams {
        CommandParams {
            laser_on: false,
            smoothing: 128_u8,
            max_slew: 0_u8,
            dispense: None,
        }
    }

    fn home_solution() -> TargetingSolution {
        TargetingSolution {
            pan: PAN_HOME,
            tilt: TILT_HOME,
        }
    }

    // --- build_command: pan and tilt ---

    #[test]
    fn test_build_command_uses_solution_angles() {
        let solution = TargetingSolution {
            pan: 4523_i16,
            tilt: -1000_i16,
        };
        let cmd = build_command(solution, default_params());

        assert_eq!(cmd.pan(), 4523_i16, "pan must come from targeting solution");
        assert_eq!(
            cmd.tilt(),
            -1000_i16,
            "tilt must come from targeting solution"
        );
    }

    #[test]
    fn test_build_command_home_position() {
        let cmd = build_command(home_solution(), default_params());

        assert_eq!(cmd.pan(), PAN_HOME, "pan must be PAN_HOME");
        assert_eq!(cmd.tilt(), TILT_HOME, "tilt must be TILT_HOME");
    }

    #[test]
    fn test_build_command_extreme_angles() {
        let solution = TargetingSolution {
            pan: i16::MIN,
            tilt: i16::MAX,
        };
        let cmd = build_command(solution, default_params());

        assert_eq!(
            cmd.pan(),
            i16::MIN,
            "extreme negative pan must pass through"
        );
        assert_eq!(
            cmd.tilt(),
            i16::MAX,
            "extreme positive tilt must pass through"
        );
    }

    // --- build_command: smoothing and max_slew ---

    #[test]
    fn test_build_command_smoothing_and_slew_passthrough() {
        let params = CommandParams {
            laser_on: false,
            smoothing: 200_u8,
            max_slew: 150_u8,
            dispense: None,
        };
        let cmd = build_command(home_solution(), params);

        assert_eq!(cmd.smoothing(), 200_u8, "smoothing must pass through");
        assert_eq!(cmd.max_slew(), 150_u8, "max_slew must pass through");
    }

    // --- build_command: laser flag ---

    #[test]
    fn test_build_command_laser_on() {
        let params = CommandParams {
            laser_on: true,
            ..default_params()
        };
        let cmd = build_command(home_solution(), params);

        assert!(
            cmd.flags().laser_on(),
            "laser flag must be set when laser_on is true"
        );
    }

    #[test]
    fn test_build_command_laser_off() {
        let params = CommandParams {
            laser_on: false,
            ..default_params()
        };
        let cmd = build_command(home_solution(), params);

        assert!(
            !cmd.flags().laser_on(),
            "laser flag must be clear when laser_on is false"
        );
    }

    // --- build_command: reserved bit 1 stays clear ---

    #[test]
    fn test_build_command_reserved_bit_one_clear_for_all_flags_set() {
        // Regression guard for the removed person-detected flag. The
        // Secure world treats bit 1 as reserved; any non-zero value
        // here would be a wire-format violation that could block a
        // future behavior-only extension.
        let params = CommandParams {
            laser_on: true,
            smoothing: 255_u8,
            max_slew: 200_u8,
            dispense: Some(DispenseRequest {
                direction: DispenseDirection::Right,
                tier: 2_u8,
            }),
        };
        let cmd = build_command(home_solution(), params);
        assert_eq!(
            cmd.flags().raw() & 0x02_u8,
            0_u8,
            "bit 1 of flags must remain clear — no safety input crosses the UART",
        );
    }

    // --- build_command: dispense flags ---

    #[test]
    fn test_build_command_dispense_left() {
        let params = CommandParams {
            dispense: Some(DispenseRequest {
                direction: DispenseDirection::Left,
                tier: 1_u8,
            }),
            ..default_params()
        };
        let cmd = build_command(home_solution(), params);

        assert!(
            cmd.flags().dispense_left(),
            "dispense_left must be set for Left direction"
        );
        assert!(
            !cmd.flags().dispense_right(),
            "dispense_right must be clear for Left direction"
        );
        assert_eq!(
            cmd.flags().dispense_tier(),
            1_u8,
            "dispense tier must match request"
        );
        assert_eq!(
            cmd.flags().dispense_direction(),
            Some(DispenseDirection::Left),
            "dispense_direction must round-trip as Left"
        );
    }

    #[test]
    fn test_build_command_dispense_right() {
        let params = CommandParams {
            dispense: Some(DispenseRequest {
                direction: DispenseDirection::Right,
                tier: 2_u8,
            }),
            ..default_params()
        };
        let cmd = build_command(home_solution(), params);

        assert!(
            !cmd.flags().dispense_left(),
            "dispense_left must be clear for Right direction"
        );
        assert!(
            cmd.flags().dispense_right(),
            "dispense_right must be set for Right direction"
        );
        assert_eq!(
            cmd.flags().dispense_tier(),
            2_u8,
            "dispense tier must match request"
        );
        assert_eq!(
            cmd.flags().dispense_direction(),
            Some(DispenseDirection::Right),
            "dispense_direction must round-trip as Right"
        );
    }

    #[test]
    fn test_build_command_no_dispense() {
        let cmd = build_command(home_solution(), default_params());

        assert!(
            !cmd.flags().dispense_left(),
            "dispense_left must be clear when no dispense"
        );
        assert!(
            !cmd.flags().dispense_right(),
            "dispense_right must be clear when no dispense"
        );
        assert_eq!(
            cmd.flags().dispense_tier(),
            0_u8,
            "dispense tier must be 0 when no dispense"
        );
        assert_eq!(
            cmd.flags().dispense_direction(),
            None,
            "dispense_direction must be None when no dispense"
        );
    }

    #[test]
    fn test_build_command_dispense_all_tiers() {
        for tier in 0_u8..=2_u8 {
            let params = CommandParams {
                dispense: Some(DispenseRequest {
                    direction: DispenseDirection::Left,
                    tier,
                }),
                ..default_params()
            };
            let cmd = build_command(home_solution(), params);

            assert_eq!(
                cmd.flags().dispense_tier(),
                tier,
                "tier {tier} must round-trip through build_command"
            );
        }
    }

    // --- build_command: combined flags ---

    #[test]
    fn test_build_command_all_flags_set() {
        let params = CommandParams {
            laser_on: true,
            smoothing: 255_u8,
            max_slew: 200_u8,
            dispense: Some(DispenseRequest {
                direction: DispenseDirection::Right,
                tier: 2_u8,
            }),
        };
        let cmd = build_command(home_solution(), params);

        assert!(cmd.flags().laser_on(), "laser must be on");
        assert!(cmd.flags().dispense_right(), "dispense_right must be set");
        assert_eq!(cmd.flags().dispense_tier(), 2_u8, "tier must be 2");
    }

    // --- build_command: checksum validity ---

    #[test]
    fn test_build_command_valid_checksum() {
        let cmd = build_command(home_solution(), default_params());

        assert!(
            cmd.verify_checksum(),
            "built command must have a valid checksum"
        );
    }

    #[test]
    fn test_build_command_round_trips_through_bytes() {
        let params = CommandParams {
            laser_on: true,
            smoothing: 64_u8,
            max_slew: 100_u8,
            dispense: Some(DispenseRequest {
                direction: DispenseDirection::Left,
                tier: 1_u8,
            }),
        };
        let solution = TargetingSolution {
            pan: -3500_i16,
            tilt: 6000_i16,
        };
        let cmd = build_command(solution, params);
        let bytes = cmd.to_bytes();
        let recovered = ServoCommand::from_bytes(bytes);

        assert_eq!(
            recovered,
            Ok(cmd),
            "built command must survive byte round-trip"
        );
    }

    // --- Proptest ---

    fn arb_targeting_solution() -> impl Strategy<Value = TargetingSolution> {
        (any::<i16>(), any::<i16>()).prop_map(|(pan, tilt)| TargetingSolution { pan, tilt })
    }

    fn arb_dispense_request() -> impl Strategy<Value = Option<DispenseRequest>> {
        prop_oneof![
            Just(None),
            (
                prop_oneof![
                    Just(DispenseDirection::Left),
                    Just(DispenseDirection::Right)
                ],
                0_u8..=2_u8
            )
                .prop_map(|(direction, tier)| Some(DispenseRequest { direction, tier })),
        ]
    }

    fn arb_command_params() -> impl Strategy<Value = CommandParams> {
        (
            any::<bool>(),
            any::<u8>(),
            any::<u8>(),
            arb_dispense_request(),
        )
            .prop_map(|(laser_on, smoothing, max_slew, dispense)| CommandParams {
                laser_on,
                smoothing,
                max_slew,
                dispense,
            })
    }

    proptest! {
        #[test]
        fn test_build_command_always_valid_checksum(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            prop_assert!(
                cmd.verify_checksum(),
                "built command must always have valid checksum",
            );
        }

        #[test]
        fn test_build_command_always_round_trips(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            let bytes = cmd.to_bytes();
            let recovered = ServoCommand::from_bytes(bytes);
            prop_assert_eq!(
                recovered,
                Ok(cmd),
                "built command must always survive byte round-trip",
            );
        }

        #[test]
        fn test_build_command_pan_tilt_from_solution(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            prop_assert_eq!(cmd.pan(), solution.pan, "pan must equal solution.pan");
            prop_assert_eq!(cmd.tilt(), solution.tilt, "tilt must equal solution.tilt");
        }

        #[test]
        fn test_build_command_reserved_bit_one_always_clear(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            prop_assert_eq!(
                cmd.flags().raw() & 0x02_u8,
                0_u8,
                "bit 1 of flags must remain clear for every build_command input",
            );
        }

        #[test]
        fn test_build_command_laser_flag_matches_params(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            prop_assert_eq!(
                cmd.flags().laser_on(),
                params.laser_on,
                "laser_on flag must match params.laser_on",
            );
        }

        #[test]
        fn test_build_command_smoothing_slew_match_params(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            prop_assert_eq!(
                cmd.smoothing(),
                params.smoothing,
                "smoothing must match params",
            );
            prop_assert_eq!(
                cmd.max_slew(),
                params.max_slew,
                "max_slew must match params",
            );
        }

        #[test]
        fn test_build_command_dispense_direction_matches_params(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            let expected_direction = params.dispense.map(|d| d.direction);
            prop_assert_eq!(
                cmd.flags().dispense_direction(),
                expected_direction,
                "dispense direction must match params",
            );
        }

        #[test]
        fn test_build_command_dispense_tier_matches_params(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            let expected_tier = params.dispense.map_or(0_u8, |d| d.tier);
            prop_assert_eq!(
                cmd.flags().dispense_tier(),
                expected_tier,
                "dispense tier must match params (0 when no dispense)",
            );
        }

        #[test]
        fn test_build_command_parseable_by_frame_parser(
            solution in arb_targeting_solution(),
            params in arb_command_params(),
        ) {
            let cmd = build_command(solution, params);
            let bytes = cmd.to_bytes();

            let mut parser = catlaser_common::FrameParser::new();
            let mut result = None;
            for &b in &bytes {
                if let Some(c) = parser.push(b) {
                    result = Some(c);
                }
            }
            prop_assert_eq!(
                result,
                Some(cmd),
                "built command must be parseable by MCU FrameParser",
            );
        }
    }
}
