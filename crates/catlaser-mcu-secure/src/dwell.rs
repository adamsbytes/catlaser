//! Beam-motion enforcement for Class 2 eye safety.
//!
//! The Secure world samples the pan and tilt PWM compare registers
//! directly from hardware and tracks how long the beam has been
//! stationary. If the combined tick delta stays strictly below
//! [`DWELL_MOTION_THRESHOLD_TICKS`] for
//! [`DWELL_MAX_STATIONARY_SAMPLES`] consecutive samples, the gateway
//! refuses to enable the laser (or forces it off if already on).
//!
//! Combined with a Class 2 (≤1 mW visible CW) laser diode, this
//! bounds the maximum retinal exposure time at any beam-termination
//! point to less than the blink-reflex window assumed by IEC 60825-1.
//! Eye safety then holds for any enclosure orientation, any mount
//! height, and any pointing direction — the safety argument is
//! dose-per-exposure, not pointing geometry.
//!
//! # Why PWM compare, not a reported angle
//!
//! The Non-Secure firmware computes the commanded servo angles and
//! writes them to PWM compare registers A (pan, slice 1) and B (tilt,
//! slice 1). Those writes are the authoritative record of where the
//! servos are being driven — the servo itself mechanically tracks them.
//! Reading the compare registers from the Secure side means the Secure
//! world cannot be lied to about beam position by the Non-Secure
//! firmware: a malicious image that reports motion while holding PWM
//! constant would have the Secure world observe the true (stationary)
//! hardware state. ACCESSCTRL leaves the PWM peripheral fully
//! accessible from all security levels, so the Secure world can read
//! without blocking the Non-Secure control loop's writes.
//!
//! # State machine
//!
//! The monitor holds `stationary_samples`, the count of consecutive
//! [`sample_and_advance`] calls where no motion was observed. On each
//! call:
//!
//! 1. Read the current (A, B) compare values from `PWM_SLICE_1_CC`.
//! 2. If no previous sample exists, seed `last_cc` and leave
//!    `stationary_samples` at its initial (saturated) value.
//! 3. Otherwise compute `|delta_a| + |delta_b|`. If the sum is at
//!    least [`DWELL_MOTION_THRESHOLD_TICKS`], reset `stationary_samples`
//!    to zero; otherwise increment it (saturating).
//!
//! [`beam_moving_cs`] reports `true` iff `stationary_samples` is below
//! the allowed window. On boot `stationary_samples` is pinned at
//! `DWELL_MAX_STATIONARY_SAMPLES`, so the laser cannot be turned on
//! until the Non-Secure firmware has actually commanded motion.

use core::cell::Cell;

use critical_section::{CriticalSection, Mutex};
use embassy_rp::pac;

use catlaser_common::constants::{DWELL_MAX_STATIONARY_SAMPLES, DWELL_MOTION_THRESHOLD_TICKS};

/// PWM slice carrying the pan + tilt compare values.
///
/// Both servos share slice 1: channel A (low 16 bits of `cc`) drives
/// pan (`PIN_SERVO_PAN` = GPIO 2, function PWM), channel B (high 16
/// bits of `cc`) drives tilt (`PIN_SERVO_TILT` = GPIO 3). Confirmed
/// by the Non-Secure [`control_task`](../../../catlaser-mcu/src/control.rs)
/// which configures `pwm_cfg.compare_a = pan` and `pwm_cfg.compare_b = tilt`
/// on slice 1.
const PWM_SLICE_INDEX: usize = 1_usize;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Previously-observed compare values, or `None` before the first
/// sample. Stored as `Option<(u16, u16)>` so the first-sample case
/// has no ambiguity with a legitimate zero reading.
static LAST_CC: Mutex<Cell<Option<(u16, u16)>>> = Mutex::new(Cell::new(None));

/// Count of consecutive samples without observable motion. Saturates
/// at `u32::MAX` so there is no overflow path; we only ever compare
/// against the small window constant.
static STATIONARY_SAMPLES: Mutex<Cell<u32>> = Mutex::new(Cell::new(u32::MAX));

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// Resets the dwell monitor to its "laser denied" start-of-day state.
///
/// Called from `gateway::init` during Secure boot, inside an existing
/// critical section. Must not take the critical section itself — the
/// caller already holds it.
///
/// Initial `stationary_samples = DWELL_MAX_STATIONARY_SAMPLES` means
/// [`beam_moving_cs`] returns `false` until the Non-Secure firmware
/// has commanded enough motion to reset the counter. The laser cannot
/// turn on between boot and first motion.
pub fn init_cs(cs: CriticalSection<'_>) {
    LAST_CC.borrow(cs).set(None);
    STATIONARY_SAMPLES
        .borrow(cs)
        .set(DWELL_MAX_STATIONARY_SAMPLES);
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

/// Reads the current pan + tilt PWM compare values and advances the
/// stationary counter.
///
/// Called from the `feed_watchdog` gateway on every NS tick (100 Hz by
/// default via [`WATCHDOG_CHECK_HZ`](catlaser_common::constants::WATCHDOG_CHECK_HZ)).
/// The read is a single `u32` load from `PWM_CH1_CC` — two u16 fields
/// packed into one register — so the pan and tilt samples are
/// intrinsically consistent even without a critical section around the
/// read itself.
pub fn sample_and_advance() {
    let cc = pac::PWM.ch(PWM_SLICE_INDEX).cc().read();
    let pan = cc.a();
    let tilt = cc.b();

    critical_section::with(|cs| {
        let prev = LAST_CC.borrow(cs).get();
        LAST_CC.borrow(cs).set(Some((pan, tilt)));

        let Some((prev_pan, prev_tilt)) = prev else {
            // First sample after boot or reset: nothing to diff
            // against. Leave the stationary counter alone (it was
            // pinned at DWELL_MAX_STATIONARY_SAMPLES by init_cs, so
            // the laser stays denied until actual motion arrives).
            return;
        };

        let delta_pan = pan.abs_diff(prev_pan);
        let delta_tilt = tilt.abs_diff(prev_tilt);
        // u16 + u16 cannot overflow in u32; saturating_add is defensive
        // against a future widening of the underlying types.
        let combined = u32::from(delta_pan).saturating_add(u32::from(delta_tilt));

        let counter = STATIONARY_SAMPLES.borrow(cs);
        if combined >= u32::from(DWELL_MOTION_THRESHOLD_TICKS) {
            counter.set(0_u32);
        } else {
            counter.set(counter.get().saturating_add(1_u32));
        }
    });
}

// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------

/// Returns `true` if the beam has moved recently enough to permit
/// laser activation. Must be called from within an existing critical
/// section (the gateway already holds one to read its own state
/// atomically with the dwell state).
pub fn beam_moving_cs(cs: CriticalSection<'_>) -> bool {
    STATIONARY_SAMPLES.borrow(cs).get() < DWELL_MAX_STATIONARY_SAMPLES
}
