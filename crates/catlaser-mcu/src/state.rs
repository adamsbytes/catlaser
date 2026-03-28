//! Global shared state for inter-task communication.
//!
//! All state is accessed via [`critical_section::Mutex`] wrapping [`Cell`],
//! the standard pattern for sharing [`Copy`] types between cooperative tasks
//! on single-core Cortex-M. Critical sections are interrupt disables —
//! effectively zero-cost on RP2040.

use core::cell::Cell;

use critical_section::Mutex;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;

use catlaser_common::{DispenseDirection, ServoCommand};

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
/// - **Read by:** control loop task (overrides `LATEST_CMD` when set),
///   dispenser task (aborts sequence on power loss)
pub static POWER_LOST: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

/// Debounced hopper empty state from the IR break-beam sensor.
///
/// `true` = hopper is empty (beam clear for [`HOPPER_DEBOUNCE_THRESHOLD`]
/// consecutive readings). `false` = treats present (default).
///
/// - **Written by:** hopper task (on debounced state change)
/// - **Read by:** any task needing hopper status (informational)
pub static HOPPER_EMPTY: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

// ---------------------------------------------------------------------------
// Dispenser inter-task communication
// ---------------------------------------------------------------------------

/// Request to run the treat dispense sequence.
///
/// Published by the control loop on rising edge of dispense flags in
/// [`ServoCommand`]. Consumed by the dispenser task.
#[derive(Debug, Clone, Copy)]
pub struct DispenseRequest {
    /// Which chute exit to route treats toward.
    pub direction: DispenseDirection,
    /// Dispense tier (0-2), indexes into the MCU rotation count table.
    pub tier: u8,
}

/// Signal carrying a [`DispenseRequest`] from the control loop to the
/// dispenser task. Uses last-writer-wins semantics — if signaled multiple
/// times before the dispenser reads, only the most recent request is kept.
///
/// - **Written by:** control loop task (on dispense flag transition)
/// - **Read by:** dispenser task (runs the physical sequence)
pub static DISPENSE_SIGNAL: Signal<CriticalSectionRawMutex, DispenseRequest> = Signal::new();

/// Set `true` while the dispenser task is running a dispense sequence.
/// The control loop checks this before signaling to prevent re-triggering
/// mid-sequence.
///
/// - **Written by:** dispenser task (set on start, clear on finish)
/// - **Read by:** control loop task (gate for dispense signal)
pub static DISPENSING: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));
