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
//! - [`report_tilt`] -- stores tilt angles, forces laser off if the new
//!   tilt creates a safety violation while the laser is on
//! - [`feed_watchdog`] -- audits invariants, feeds the hardware watchdog
//! - [`report_person_detected`] -- stores flag, forces laser off if the
//!   tilt now violates the tighter person-detected horizon limit
//!
//! # State
//!
//! The Secure world maintains its own copy of safety-relevant state:
//! laser on/off, current tilt pitch/roll, person-detected flag, and
//! watchdog active flag. All state is accessed via
//! <code>[critical_section::Mutex]<[Cell]<T>></code> for safe access from
//! Secure interrupt handlers (added in the next build step).
//!
//! # ABI boundary
//!
//! Gateway parameters use `u32`/`i32` (one register each) rather than
//! `bool`/`i16` to be explicit about the CMSE register-passing ABI.
//! All inputs are validated and clamped -- the NS world is untrusted.

use core::cell::Cell;

use critical_section::Mutex;
use embassy_rp::pac;

use catlaser_common::constants::{PIN_LASER, TILT_HOME, WATCHDOG_TIMEOUT_MS};
use catlaser_common::trustzone::{GatewayStatus, check_laser_safety, is_tilt_safe};

// ---------------------------------------------------------------------------
// Secure-side state
// ---------------------------------------------------------------------------

/// Whether the laser GPIO is currently driven HIGH.
static LASER_ON: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

/// Person-detected flag reported by the Non-Secure firmware.
static PERSON_DETECTED: Mutex<Cell<bool>> = Mutex::new(Cell::new(false));

/// Current tilt pitch (hundredths of a degree) reported by NS firmware.
/// Initialized to [`TILT_HOME`] (safe downward angle).
static TILT_PITCH: Mutex<Cell<i16>> = Mutex::new(Cell::new(TILT_HOME));

/// Current tilt roll (hundredths of a degree) reported by NS firmware.
static TILT_ROLL: Mutex<Cell<i16>> = Mutex::new(Cell::new(0_i16));

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

/// Clamps an `i32` to the `i16` range.
///
/// Used at the NS-to-S ABI boundary where tilt values arrive as `i32`
/// register values and must be narrowed safely.
fn clamp_to_i16(val: i32) -> i16 {
    match i16::try_from(val) {
        Ok(v) => v,
        Err(_) if val < 0_i32 => i16::MIN,
        Err(_) => i16::MAX,
    }
}

/// Forces the laser off unconditionally. Drives GPIO LOW first (fail-safe
/// direction), then updates the state flag.
///
/// Idempotent -- calling when the laser is already off is harmless.
///
/// `pub(crate)` for use by Secure interrupt handlers (step 3).
pub(crate) fn force_laser_off() {
    laser_gpio_set(false);
    critical_section::with(|cs| {
        LASER_ON.borrow(cs).set(false);
    });
    defmt::warn!("gateway: laser forced OFF");
}

/// Audits safety invariants and forces the laser off if any are violated.
///
/// Called by [`feed_watchdog`] and internally by [`report_tilt`] /
/// [`report_person_detected`] after updating state.
fn audit_and_correct() {
    let should_kill = critical_section::with(|cs| {
        let laser = LASER_ON.borrow(cs).get();
        if !laser {
            return false;
        }
        let tilt = TILT_PITCH.borrow(cs).get();
        let person = PERSON_DETECTED.borrow(cs).get();
        !is_tilt_safe(tilt, person)
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
        PERSON_DETECTED.borrow(cs).set(false);
        TILT_PITCH.borrow(cs).set(TILT_HOME);
        TILT_ROLL.borrow(cs).set(0_i16);
        WATCHDOG_ACTIVE.borrow(cs).set(false);
    });

    defmt::info!("gateway: state initialized, watchdog deferred to first feed");
}

// ---------------------------------------------------------------------------
// NSC gateway functions
// ---------------------------------------------------------------------------

/// Requests a laser state change.
///
/// - `on = 0`: turn laser off (always succeeds)
/// - `on != 0`: turn laser on (requires all safety invariants to pass)
///
/// Returns [`GatewayStatus::to_raw`] -- 0 on success, non-zero error code
/// identifying which invariant blocked activation.
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
        let tilt = TILT_PITCH.borrow(cs).get();
        let person = PERSON_DETECTED.borrow(cs).get();
        let wd_active = WATCHDOG_ACTIVE.borrow(cs).get();

        let result = check_laser_safety(tilt, person, wd_active);
        if result.is_ok() {
            laser_gpio_set(true);
            LASER_ON.borrow(cs).set(true);
        }
        result
    });

    status.to_raw()
}

/// Reports the current tilt angles from the Non-Secure firmware.
///
/// Pitch and roll arrive as `i32` (one ARM register each). Values
/// outside `i16` range are clamped. If the new tilt violates the
/// applicable horizon limit while the laser is on, the laser is
/// forced off immediately.
#[unsafe(no_mangle)]
pub extern "cmse-nonsecure-entry" fn report_tilt(pitch: i32, roll: i32) {
    let pitch_i16 = clamp_to_i16(pitch);
    let roll_i16 = clamp_to_i16(roll);

    critical_section::with(|cs| {
        TILT_PITCH.borrow(cs).set(pitch_i16);
        TILT_ROLL.borrow(cs).set(roll_i16);
    });

    audit_and_correct();
}

/// Feeds the hardware watchdog.
///
/// On the first call, starts the watchdog with a
/// [`WATCHDOG_TIMEOUT_MS`] timeout. Subsequent calls reload the
/// countdown timer.
///
/// Before feeding, audits safety invariants: if the laser is on while
/// the tilt violates the horizon limit, forces the laser off. This
/// provides a periodic safety check independent of [`set_laser_state`].
#[unsafe(no_mangle)]
pub extern "cmse-nonsecure-entry" fn feed_watchdog() {
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

/// Reports the person-detected state from the Non-Secure firmware.
///
/// - `detected = 0`: no person in frame
/// - `detected != 0`: person detected (tighter tilt limit applies)
///
/// When a person is newly detected and the current tilt violates the
/// stricter [`TILT_HORIZON_LIMIT_PERSON`](catlaser_common::constants::TILT_HORIZON_LIMIT_PERSON)
/// while the laser is on, the laser is forced off immediately.
#[unsafe(no_mangle)]
pub extern "cmse-nonsecure-entry" fn report_person_detected(detected: u32) {
    critical_section::with(|cs| {
        PERSON_DETECTED.borrow(cs).set(detected != 0_u32);
    });

    audit_and_correct();
}
