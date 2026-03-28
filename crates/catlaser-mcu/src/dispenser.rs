//! Treat dispenser servo control.
//!
//! Drives the disc, door, and deflector servos through a timed dispense
//! sequence triggered by the control loop when dispense flags appear in
//! [`ServoCommand`](catlaser_common::ServoCommand).
//!
//! # Dispense sequence
//!
//! 1. Position deflector (left or right, per command flags)
//! 2. Rotate disc N times (tier 0 = 3, tier 1 = 5, tier 2 = 7 rotations)
//! 3. Open door, dwell for treats to drop, close door
//! 4. Return deflector to center
//!
//! # Safety
//!
//! Safety is checked every 100 ms during the sequence:
//! - Power loss ([`POWER_LOST`](crate::state::POWER_LOST)) — abort, close door
//! - Command staleness (compute module unresponsive) — abort, close door
//! - Jam timeout (sequence exceeds maximum duration) — abort, close door
//!
//! The door servo is fail-closed by gravity — power loss or MCU reset
//! results in the door falling shut without servo assistance.

use embassy_rp::pwm::{self, Pwm};
use embassy_time::{Duration, Instant, Timer};
use fixed::traits::ToFixed as _;

use catlaser_common::DispenseDirection;
use catlaser_common::constants::{
    DEFLECTOR_CENTER, DEFLECTOR_LEFT, DEFLECTOR_RIGHT, DEFLECTOR_SETTLE_MS, DISC_CLOSED,
    DISC_DWELL_MS, DISC_OPEN, DISC_TRAVEL_MS, DISPENSE_JAM_TIMEOUT_MS, DOOR_CLOSED, DOOR_OPEN,
    DOOR_OPEN_DWELL_MS, DOOR_TRAVEL_MS, PWM_DIVIDER, PWM_TOP, WATCHDOG_TIMEOUT_MS,
    dispense_rotations, is_command_stale,
};
use catlaser_common::servo_math;

use crate::state::{DISPENSE_SIGNAL, DISPENSING, LAST_RX_TICKS, POWER_LOST};

/// Maximum sleep interval between safety checks during the dispense
/// sequence (milliseconds). Shorter intervals reduce worst-case delay
/// between a safety event and the abort response.
const SAFETY_CHECK_INTERVAL_MS: u64 = 100_u64;

// ---------------------------------------------------------------------------
// Abort reason
// ---------------------------------------------------------------------------

/// Reason the dispense sequence was aborted before completion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, defmt::Format)]
enum DispenseAbort {
    /// VBUS power loss detected.
    PowerLost,
    /// Compute module stopped sending commands.
    CommandTimeout,
    /// Sequence exceeded maximum allowed duration.
    JamTimeout,
    /// Reserved dispense tier (3) in command flags.
    InvalidTier,
}

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

/// Treat dispenser task.
///
/// Waits for [`DISPENSE_SIGNAL`] from the control loop, then executes the
/// dispense sequence on the disc/door/deflector servos. Checks safety at
/// every step and forces the door closed on any abort.
///
/// # PWM ownership
///
/// - `disc_door_pwm`: PWM slice 2 — channel A (disc, GPIO4), channel B
///   (door, GPIO5)
/// - `deflector_pwm`: PWM slice 3 — channel A (deflector, GPIO6)
#[embassy_executor::task]
pub async fn dispenser_task(mut disc_door_pwm: Pwm<'static>, mut deflector_pwm: Pwm<'static>) {
    defmt::info!("dispenser: ready");

    // Local PWM configs — updated in-place and applied via set_config.
    let mut dd_cfg = base_pwm_config();
    dd_cfg.compare_a = servo_math::angle_to_ticks(DISC_CLOSED);
    dd_cfg.compare_b = servo_math::angle_to_ticks(DOOR_CLOSED);
    disc_door_pwm.set_config(&dd_cfg);

    let mut defl_cfg = base_pwm_config();
    defl_cfg.compare_a = servo_math::angle_to_ticks(DEFLECTOR_CENTER);
    deflector_pwm.set_config(&defl_cfg);

    loop {
        let request = DISPENSE_SIGNAL.wait().await;

        critical_section::with(|cs| DISPENSING.borrow(cs).set(true));

        let dir_str = match request.direction {
            DispenseDirection::Left => "left",
            DispenseDirection::Right => "right",
        };
        defmt::info!(
            "dispenser: starting (dir={}, tier={})",
            dir_str,
            request.tier
        );

        let result = run_sequence(
            &mut disc_door_pwm,
            &mut dd_cfg,
            &mut deflector_pwm,
            &mut defl_cfg,
            request,
        )
        .await;

        match result {
            Ok(()) => defmt::info!("dispenser: sequence complete"),
            Err(abort) => {
                defmt::warn!("dispenser: aborted: {}", abort);
                force_safe_state(
                    &mut disc_door_pwm,
                    &mut dd_cfg,
                    &mut deflector_pwm,
                    &mut defl_cfg,
                );
            }
        }

        critical_section::with(|cs| DISPENSING.borrow(cs).set(false));
    }
}

// ---------------------------------------------------------------------------
// Sequence
// ---------------------------------------------------------------------------

/// Executes the full dispense sequence.
///
/// 1. Position deflector (left or right)
/// 2. Rotate disc N times (open → dwell → close per rotation)
/// 3. Open door, dwell for treats to drop, close door
/// 4. Return deflector to center
async fn run_sequence(
    dd_pwm: &mut Pwm<'static>,
    dd_cfg: &mut pwm::Config,
    defl_pwm: &mut Pwm<'static>,
    defl_cfg: &mut pwm::Config,
    request: crate::state::DispenseRequest,
) -> Result<(), DispenseAbort> {
    let start_ticks = Instant::now().as_ticks();
    let wd_ticks = Duration::from_millis(u64::from(WATCHDOG_TIMEOUT_MS)).as_ticks();
    let jam_ticks = Duration::from_millis(u64::from(DISPENSE_JAM_TIMEOUT_MS)).as_ticks();

    let rotations = dispense_rotations(request.tier).ok_or(DispenseAbort::InvalidTier)?;

    // 1. Position deflector.
    let deflector_angle = match request.direction {
        DispenseDirection::Left => DEFLECTOR_LEFT,
        DispenseDirection::Right => DEFLECTOR_RIGHT,
    };
    set_deflector(defl_pwm, defl_cfg, deflector_angle);
    safe_delay(DEFLECTOR_SETTLE_MS, start_ticks, wd_ticks, jam_ticks).await?;

    // 2. Rotate disc N times.
    let mut completed = 0_u8;
    while completed < rotations {
        // Open disc — holes align, one treat drops into staging chute.
        set_disc(dd_pwm, dd_cfg, DISC_OPEN);
        safe_delay(DISC_TRAVEL_MS, start_ticks, wd_ticks, jam_ticks).await?;
        safe_delay(DISC_DWELL_MS, start_ticks, wd_ticks, jam_ticks).await?;

        // Close disc — holes misalign, chute sealed.
        set_disc(dd_pwm, dd_cfg, DISC_CLOSED);
        safe_delay(DISC_TRAVEL_MS, start_ticks, wd_ticks, jam_ticks).await?;

        completed = completed.saturating_add(1_u8);
    }

    // 3. Open door — treats drop to floor on selected side.
    set_door(dd_pwm, dd_cfg, DOOR_OPEN);
    safe_delay(DOOR_TRAVEL_MS, start_ticks, wd_ticks, jam_ticks).await?;
    safe_delay(DOOR_OPEN_DWELL_MS, start_ticks, wd_ticks, jam_ticks).await?;

    // 4. Close door.
    set_door(dd_pwm, dd_cfg, DOOR_CLOSED);
    safe_delay(DOOR_TRAVEL_MS, start_ticks, wd_ticks, jam_ticks).await?;

    // 5. Return deflector to center.
    set_deflector(defl_pwm, defl_cfg, DEFLECTOR_CENTER);
    safe_delay(DEFLECTOR_SETTLE_MS, start_ticks, wd_ticks, jam_ticks).await?;

    Ok(())
}

// ---------------------------------------------------------------------------
// PWM helpers
// ---------------------------------------------------------------------------

/// Base PWM config for 50 Hz servo signal (shared by all servo slices).
fn base_pwm_config() -> pwm::Config {
    let mut cfg = pwm::Config::default();
    cfg.top = PWM_TOP;
    cfg.divider = PWM_DIVIDER.to_fixed();
    cfg
}

/// Sets the disc servo position (PWM slice 2, channel A).
fn set_disc(pwm: &mut Pwm<'static>, cfg: &mut pwm::Config, angle: i16) {
    cfg.compare_a = servo_math::angle_to_ticks(angle);
    pwm.set_config(cfg);
}

/// Sets the door servo position (PWM slice 2, channel B).
fn set_door(pwm: &mut Pwm<'static>, cfg: &mut pwm::Config, angle: i16) {
    cfg.compare_b = servo_math::angle_to_ticks(angle);
    pwm.set_config(cfg);
}

/// Sets the deflector servo position (PWM slice 3, channel A).
fn set_deflector(pwm: &mut Pwm<'static>, cfg: &mut pwm::Config, angle: i16) {
    cfg.compare_a = servo_math::angle_to_ticks(angle);
    pwm.set_config(cfg);
}

/// Forces all dispenser servos to safe resting positions.
///
/// Disc closed, door closed, deflector centered.
fn force_safe_state(
    dd_pwm: &mut Pwm<'static>,
    dd_cfg: &mut pwm::Config,
    defl_pwm: &mut Pwm<'static>,
    defl_cfg: &mut pwm::Config,
) {
    dd_cfg.compare_a = servo_math::angle_to_ticks(DISC_CLOSED);
    dd_cfg.compare_b = servo_math::angle_to_ticks(DOOR_CLOSED);
    dd_pwm.set_config(dd_cfg);

    defl_cfg.compare_a = servo_math::angle_to_ticks(DEFLECTOR_CENTER);
    defl_pwm.set_config(defl_cfg);
}

// ---------------------------------------------------------------------------
// Safety-checked delay
// ---------------------------------------------------------------------------

/// Sleeps for `ms` milliseconds, checking safety every
/// [`SAFETY_CHECK_INTERVAL_MS`].
///
/// Returns `Err` on the first failed check — caller must close the door.
async fn safe_delay(
    ms: u32,
    start_ticks: u64,
    wd_ticks: u64,
    jam_ticks: u64,
) -> Result<(), DispenseAbort> {
    let delay_ticks = Duration::from_millis(u64::from(ms)).as_ticks();
    let begin_ticks = Instant::now().as_ticks();
    let step = Duration::from_millis(SAFETY_CHECK_INTERVAL_MS);

    loop {
        check_safety(start_ticks, wd_ticks, jam_ticks)?;

        let elapsed = Instant::now().as_ticks().saturating_sub(begin_ticks);
        if elapsed >= delay_ticks {
            return Ok(());
        }

        let remaining = Duration::from_ticks(delay_ticks.saturating_sub(elapsed));
        Timer::after(if remaining < step { remaining } else { step }).await;
    }
}

/// Checks safety invariants. Returns `Err` if the sequence must abort.
fn check_safety(start_ticks: u64, wd_ticks: u64, jam_ticks: u64) -> Result<(), DispenseAbort> {
    // Read both flags in a single critical section.
    let (power_lost, last_rx) =
        critical_section::with(|cs| (POWER_LOST.borrow(cs).get(), LAST_RX_TICKS.borrow(cs).get()));

    if power_lost {
        return Err(DispenseAbort::PowerLost);
    }

    let now_ticks = Instant::now().as_ticks();

    if is_command_stale(last_rx, now_ticks, wd_ticks) {
        return Err(DispenseAbort::CommandTimeout);
    }

    if now_ticks.saturating_sub(start_ticks) > jam_ticks {
        return Err(DispenseAbort::JamTimeout);
    }

    Ok(())
}
