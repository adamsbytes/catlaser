//! Global shared state for inter-task communication.
//!
//! All state is accessed via [`critical_section::Mutex`] wrapping [`Cell`],
//! the standard pattern for sharing [`Copy`] types between cooperative tasks
//! on single-core Cortex-M. Critical sections are interrupt disables —
//! effectively zero-cost on RP2040.

use core::cell::Cell;

use critical_section::Mutex;

use catlaser_common::ServoCommand;

/// Latest valid [`ServoCommand`] received from the compute module.
///
/// Initialized to [`ServoCommand::HOME`] (laser off, servos at home position).
///
/// - **Written by:** UART RX task (on valid checksum)
/// - **Read by:** control loop task (200Hz tick)
pub static LATEST_CMD: Mutex<Cell<ServoCommand>> = Mutex::new(Cell::new(ServoCommand::HOME));

/// Tick count ([`embassy_time::Instant`] ticks) when the last valid command
/// was received. Zero means no command has been received since boot.
///
/// - **Written by:** UART RX task (on valid checksum)
/// - **Read by:** watchdog task (compares against current time)
pub static LAST_RX_TICKS: Mutex<Cell<u64>> = Mutex::new(Cell::new(0_u64));

/// Power-loss flag. Once set, the control loop forces [`ServoCommand::HOME`]
/// regardless of incoming commands until the supercap drains and the MCU
/// resets.
///
/// One-way latch: set to `true` on VBUS threshold breach, never cleared.
///
/// - **Written by:** power monitor task (on low VBUS detection)
/// - **Read by:** control loop task (overrides `LATEST_CMD` when set)
pub static POWER_LOST: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));
