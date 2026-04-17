//! NSC (Non-Secure Callable) gateway functions for the Secure world.
//!
//! These are the only legal entry points from Non-Secure code into
//! Secure state. The CMSE ABI ensures that each call passes through
//! an `SG` (Secure Gateway) instruction in the NSC veneer region.
//!
//! # Gateway functions
//!
//! - [`set_laser_state`] -- validates safety invariants before toggling
//!   the laser GPIO
//! - [`feed_watchdog`] -- advances the dwell monitor, audits invariants,
//!   feeds the hardware watchdog
//!
//! # State
//!
//! The Secure world maintains two invariants entirely from hardware
//! observables it controls:
//!
//! - **Laser on/off** (written only by this module; Non-Secure code has
//!   no GPIO access to the laser pin).
//! - **Watchdog active** (set the first time [`feed_watchdog`] runs).
//!
//! The dwell monitor (see [`super::dwell`]) owns its own state, sampled
//! on every feed from the PWM compare registers. Nothing the Non-Secure
//! firmware says is treated as a safety input — the Secure world
//! derives everything it needs from peripherals it reads directly.
//!
//! # ABI boundary
//!
//! Gateway parameters use `u32` (one register each) rather than `bool`
//! to be explicit about the CMSE register-passing ABI. The only input
//! Non-Secure can express is the laser on/off request; it cannot
//! influence the safety decision.

use core::cell::Cell;

use critical_section::Mutex;
use embassy_rp::pac;

use catlaser_common::constants::{PIN_LASER, WATCHDOG_TIMEOUT_MS};
use catlaser_common::trustzone::{GatewayStatus, check_laser_safety};

use crate::dwell;

// ---------------------------------------------------------------------------
// Secure-side state
// ---------------------------------------------------------------------------

/// Whether the laser GPIO is currently driven HIGH.
static LASER_ON: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

/// `true` after the first [`feed_watchdog`] call starts the hardware
/// watchdog. The laser cannot turn on until this is set.
static WATCHDOG_ACTIVE: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Bit mask for the laser GPIO pin.
const LASER_PIN_MASK: u32 = 1_u32 << PIN_LASER;

/// Watchdog LOAD register value in microseconds.
///
/// The RP2350 watchdog counts down at 1 MHz (1 tick = 1 us).
const WATCHDOG_LOAD_US: u32 = WATCHDOG_TIMEOUT_MS * 1000_u32;

const _: () = assert!(
    WATCHDOG_LOAD_US == 500_000_u32,
    "WATCHDOG_LOAD_US must be 500,000 microseconds"
);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Drives the laser GPIO pin via SIO set/clear registers.
fn laser_gpio_set(on: bool) {
    let sio = pac::SIO;
    if on {
        sio.gpio_out(0).value_set().write_value(LASER_PIN_MASK);
    } else {
        sio.gpio_out(0).value_clr().write_value(LASER_PIN_MASK);
    }
}

/// Forces the laser off unconditionally. Drives GPIO LOW first (fail-safe
/// direction), then updates the state flag.
///
/// Idempotent -- calling when the laser is already off is harmless.
///
/// `pub(crate)` for use by Secure interrupt handlers (fault + brownout).
pub(crate) fn force_laser_off() {
    laser_gpio_set(false);
    critical_section::with(|cs| {
        LASER_ON.borrow(cs).set(false);
    });
    defmt::warn!("gateway: laser forced OFF");
}

/// Audits safety invariants and forces the laser off if any are violated.
///
/// Called by [`feed_watchdog`] after advancing the dwell monitor. Reads
/// beam-motion state from [`dwell`] and compares it against the invariant
/// in [`check_laser_safety`]. Any failure kills the laser — the caller
/// (the NS firmware) must wait for motion to resume before requesting
/// the laser on again.
fn audit_and_correct() {
    let should_kill = critical_section::with(|cs| {
        if !LASER_ON.borrow(cs).get() {
            return false;
        }
        let wd_active = WATCHDOG_ACTIVE.borrow(cs).get();
        !check_laser_safety(wd_active, dwell::beam_moving_cs(cs)).is_ok()
    });

    if should_kill {
        force_laser_off();
    }
}

// ---------------------------------------------------------------------------
// Public API (called from main.rs during Secure boot)
// ---------------------------------------------------------------------------

/// Initializes Secure gateway state to safe defaults.
///
/// Does NOT start the hardware watchdog -- that is deferred to the first
/// [`feed_watchdog`] call to avoid a timeout race during Non-Secure boot.
pub fn init() {
    critical_section::with(|cs| {
        LASER_ON.borrow(cs).set(false);
        WATCHDOG_ACTIVE.borrow(cs).set(false);
        dwell::init_cs(cs);
    });

    defmt::info!("gateway: state initialized, watchdog deferred to first feed");
}

// ---------------------------------------------------------------------------
// NSC gateway functions
// ---------------------------------------------------------------------------

/// Requests a laser state change.
///
/// - `on = 0`: turn laser off (always succeeds)
/// - `on != 0`: turn laser on (requires watchdog active + beam moving)
///
/// Returns [`GatewayStatus::to_raw`] -- 0 on success, non-zero error code
/// identifying which invariant blocked activation. The Non-Secure side
/// cannot carry any safety input into this call; the Secure world reads
/// the watchdog flag and the dwell monitor (PWM readback) directly.
#[unsafe(no_mangle)]
pub extern "cmse-nonsecure-entry" fn set_laser_state(on: u32) -> u32 {
    if on == 0_u32 {
        laser_gpio_set(false);
        critical_section::with(|cs| {
            LASER_ON.borrow(cs).set(false);
        });
        return GatewayStatus::Ok.to_raw();
    }

    let status = critical_section::with(|cs| {
        let wd_active = WATCHDOG_ACTIVE.borrow(cs).get();
        let beam_moving = dwell::beam_moving_cs(cs);

        let result = check_laser_safety(wd_active, beam_moving);
        if result.is_ok() {
            laser_gpio_set(true);
            LASER_ON.borrow(cs).set(true);
        }
        result
    });

    status.to_raw()
}

/// Feeds the hardware watchdog.
///
/// On the first call, starts the watchdog with a
/// [`WATCHDOG_TIMEOUT_MS`] timeout. Subsequent calls reload the
/// countdown timer.
///
/// Before feeding, the dwell monitor samples the PWM compare
/// registers for pan and tilt directly from hardware and updates
/// its stationary counter. The audit then checks the combined
/// invariant (watchdog + dwell) and forces the laser off if it
/// fails. This runs at [`WATCHDOG_CHECK_HZ`](catlaser_common::constants::WATCHDOG_CHECK_HZ) —
/// the same cadence as the dwell window — so a beam that has been
/// stationary for the permitted window is killed on the following
/// feed.
#[unsafe(no_mangle)]
pub extern "cmse-nonsecure-entry" fn feed_watchdog() {
    // Sample PWM compare registers and advance the dwell monitor
    // before any safety decision uses it.
    dwell::sample_and_advance();

    audit_and_correct();

    let wd = pac::WATCHDOG;

    let first_call = critical_section::with(|cs| {
        let active = WATCHDOG_ACTIVE.borrow(cs).get();
        if !active {
            WATCHDOG_ACTIVE.borrow(cs).set(true);
        }
        !active
    });

    if first_call {
        wd.ctrl().write(|w| w.set_enable(false));
        wd.load()
            .write_value(pac::watchdog::regs::Load(WATCHDOG_LOAD_US));
        wd.ctrl().write(|w| {
            w.set_enable(true);
            w.set_pause_dbg0(true);
            w.set_pause_dbg1(true);
        });
        defmt::info!("gateway: watchdog started ({}ms)", WATCHDOG_TIMEOUT_MS);
    } else {
        wd.load()
            .write_value(pac::watchdog::regs::Load(WATCHDOG_LOAD_US));
    }
}
