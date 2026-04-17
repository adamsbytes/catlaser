//! Non-Secure gateway interface to Secure world functions.
//!
//! These functions call through the NSC (Non-Secure Callable) veneer
//! region into the Secure image's gateway functions. The actual
//! implementations live in `catlaser-mcu-secure::gateway` -- the
//! symbols resolve at link time from the Secure image's veneer import
//! library.
//!
//! The Non-Secure side carries no safety inputs across the boundary.
//! The Secure world owns the laser GPIO, the hardware watchdog, and
//! the dwell monitor (which reads the PWM compare registers directly);
//! it decides whether to grant each laser activation from hardware
//! observables it controls. The only value the Non-Secure firmware
//! can ever express is the laser on/off request itself.

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
    fn feed_watchdog();
}

// ---------------------------------------------------------------------------
// Safe wrappers
// ---------------------------------------------------------------------------

/// Requests a laser state change from the Secure world.
///
/// Returns [`GatewayStatus::Ok`] on success. Non-Ok status indicates
/// which safety invariant prevented laser activation
/// ([`GatewayStatus::DwellViolation`] if the beam has been stationary
/// too long; [`GatewayStatus::WatchdogInactive`] before the first
/// [`watchdog_feed`] call completes). Turning the laser off
/// (`on = false`) always succeeds.
pub fn laser_set(on: bool) -> GatewayStatus {
    // SAFETY: set_laser_state is an NSC veneer function. The Secure
    // side validates the on/off parameter and checks all safety
    // invariants before toggling the laser GPIO.
    let raw = unsafe { set_laser_state(u32::from(on)) };
    GatewayStatus::from_raw(raw).unwrap_or_else(|| {
        defmt::error!("gateway: unknown laser status {}", raw);
        // Unknown status from Secure world indicates corruption.
        // Report as DwellViolation — the laser did not turn on.
        GatewayStatus::DwellViolation
    })
}

/// Feeds the hardware watchdog via the Secure world.
///
/// On the first call, starts the watchdog with the configured timeout.
/// Subsequent calls reload the countdown. The Secure side also samples
/// the PWM compare registers to advance the dwell monitor, and audits
/// the combined safety invariant — if the beam has been stationary
/// for too long while the laser is on, the laser is forced off.
pub fn watchdog_feed() {
    // SAFETY: feed_watchdog is an NSC veneer function with no
    // parameters. The Secure side manages the watchdog peripheral
    // and the dwell monitor.
    unsafe { feed_watchdog() };
}
