//! Non-Secure gateway interface to Secure world functions.
//!
//! These functions call through the NSC (Non-Secure Callable) veneer
//! region into the Secure image's gateway functions. The actual
//! implementations live in `catlaser-mcu-secure::gateway` -- the
//! symbols resolve at link time from the Secure image's veneer import
//! library.
//!
//! Each wrapper converts between idiomatic Rust types ([`bool`], [`i16`])
//! and the CMSE register-passing ABI ([`u32`], [`i32`]), matching the
//! Secure-side parameter conventions documented in
//! [`catlaser_common::trustzone`].

#![expect(
    unsafe_code,
    reason = "CMSE gateway FFI calls to Secure world veneer functions (ADR-005)"
)]

use catlaser_common::trustzone::GatewayStatus;

// ---------------------------------------------------------------------------
// Extern declarations (resolved at link time from Secure veneer library)
// ---------------------------------------------------------------------------

// These symbols are NSC (Non-Secure Callable) veneer functions exported
// by the Secure image (catlaser-mcu-secure). They use the standard C ABI
// with parameters passed in registers R0-R3. The Secure image validates
// all inputs before acting on them.
unsafe extern "C" {
    fn set_laser_state(on: u32) -> u32;
    fn report_tilt(pitch: i32, roll: i32);
    fn feed_watchdog();
    fn report_person_detected(detected: u32);
}

// ---------------------------------------------------------------------------
// Safe wrappers
// ---------------------------------------------------------------------------

/// Requests a laser state change from the Secure world.
///
/// Returns [`GatewayStatus::Ok`] on success. Non-Ok status indicates
/// which safety invariant prevented laser activation. Turning the
/// laser off (`on = false`) always succeeds.
pub fn laser_set(on: bool) -> GatewayStatus {
    // SAFETY: set_laser_state is an NSC veneer function. The Secure
    // side validates the on/off parameter and checks all safety
    // invariants before toggling the laser GPIO.
    let raw = unsafe { set_laser_state(u32::from(on)) };
    GatewayStatus::from_raw(raw).unwrap_or_else(|| {
        defmt::error!("gateway: unknown laser status {}", raw);
        // Unknown status from Secure world indicates corruption.
        // Report as TiltViolation — the laser did not turn on.
        GatewayStatus::TiltViolation
    })
}

/// Reports current tilt angles to the Secure world.
///
/// The Secure side stores these values and uses them to gate laser
/// activation. If the reported tilt violates the applicable horizon
/// limit while the laser is on, the Secure side forces the laser off
/// immediately.
pub fn tilt_report(pitch: i16, roll: i16) {
    // SAFETY: report_tilt is an NSC veneer function. i32::from(i16)
    // is a lossless widening — the Secure side clamps back to i16.
    unsafe { report_tilt(i32::from(pitch), i32::from(roll)) };
}

/// Feeds the hardware watchdog via the Secure world.
///
/// On the first call, starts the watchdog with the configured timeout.
/// Subsequent calls reload the countdown. The Secure side audits
/// safety invariants before feeding — if the laser is on while the
/// tilt violates limits, the laser is forced off.
pub fn watchdog_feed() {
    // SAFETY: feed_watchdog is an NSC veneer function with no
    // parameters. The Secure side manages the watchdog peripheral.
    unsafe { feed_watchdog() };
}

/// Reports person-detected state to the Secure world.
///
/// When a person is newly detected while the laser is on above the
/// person horizon limit, the Secure side forces the laser off
/// immediately.
pub fn person_detected_report(detected: bool) {
    // SAFETY: report_person_detected is an NSC veneer function. The
    // Secure side interprets any non-zero value as true.
    unsafe { report_person_detected(u32::from(detected)) };
}
