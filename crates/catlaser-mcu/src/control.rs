//! 200 Hz servo control loop.
//!
//! Reads the latest [`ServoCommand`](catlaser_common::ServoCommand) from shared
//! state, applies angle clamping, exponential interpolation, slew-rate limiting,
//! and outputs PWM to the pan/tilt servos at 200 Hz. Reports tilt and
//! person-detected state to the Secure world each tick, then requests laser
//! state via the [`gateway`](crate::gateway) -- the Secure side validates all
//! safety invariants before toggling the laser GPIO.

use embassy_rp::pwm::{self, Pwm};
use embassy_time::{Duration, Ticker};
use fixed::traits::ToFixed as _;

use catlaser_common::ServoCommand;
use catlaser_common::constants::{CONTROL_LOOP_HZ, PAN_HOME, PWM_DIVIDER, PWM_TOP, TILT_HOME};
use catlaser_common::servo_math;

use crate::state::{DISPENSE_SIGNAL, DISPENSING, DispenseRequest, LATEST_CMD, POWER_LOST};

/// 200 Hz servo interpolation task.
///
/// Maintains current pan/tilt angles (initialized to home) and smoothly
/// drives them toward the latest commanded target each tick. Outputs the
/// resulting angles as PWM compare values on slice 1 channels A (pan)
/// and B (tilt). Reports tilt and person-detected state to the Secure
/// world, then requests laser state via the gateway each tick.
#[embassy_executor::task]
pub async fn control_task(mut pwm: Pwm<'static>) {
    defmt::info!("control: starting 200Hz loop");

    let mut current_pan: i16 = PAN_HOME;
    let mut current_tilt: i16 = TILT_HOME;
    let mut was_dispense_active = false;

    let mut pwm_cfg = pwm::Config::default();
    pwm_cfg.top = PWM_TOP;
    pwm_cfg.divider = PWM_DIVIDER.to_fixed();
    pwm_cfg.compare_a = servo_math::angle_to_ticks(current_pan);
    pwm_cfg.compare_b = servo_math::angle_to_ticks(current_tilt);

    let mut ticker = Ticker::every(Duration::from_hz(u64::from(CONTROL_LOOP_HZ)));

    loop {
        ticker.next().await;

        let cmd = critical_section::with(|cs| {
            if POWER_LOST.borrow(cs).get() {
                ServoCommand::HOME
            } else {
                LATEST_CMD.borrow(cs).get()
            }
        });

        // Clamp targets to safe range.
        let target_pan = servo_math::clamp_pan(cmd.pan());
        let target_tilt = servo_math::clamp_tilt(cmd.tilt(), cmd.flags().person_detected());

        // Interpolate toward target.
        let next_pan = servo_math::interpolate(current_pan, target_pan, cmd.smoothing());
        let next_tilt = servo_math::interpolate(current_tilt, target_tilt, cmd.smoothing());

        // Apply slew rate limiting.
        current_pan = servo_math::slew_limit(current_pan, next_pan, cmd.max_slew());
        current_tilt = servo_math::slew_limit(current_tilt, next_tilt, cmd.max_slew());

        // Hardware horizon limit: clamp output angles after all processing.
        // When person_detected transitions true, the stricter limit takes
        // effect immediately — interpolation and slew rate cannot delay it.
        current_pan = servo_math::clamp_pan(current_pan);
        current_tilt = servo_math::clamp_tilt(current_tilt, cmd.flags().person_detected());

        // Report tilt to Secure world before requesting laser state, so
        // the Secure side has current angles for its safety check.
        crate::gateway::tilt_report(current_tilt, 0_i16);

        // Report person-detected state to Secure world. If a person is
        // newly detected while the laser is on above the person horizon
        // limit, the Secure side forces the laser off immediately.
        crate::gateway::person_detected_report(cmd.flags().person_detected());

        // Request laser state from Secure world. The Secure side validates
        // all safety invariants (tilt, person-detected, watchdog) before
        // toggling the laser GPIO.
        let status = crate::gateway::laser_set(cmd.flags().laser_on());
        if cmd.flags().laser_on() && !status.is_ok() {
            defmt::trace!("control: laser denied (status={})", status.to_raw(),);
        }

        // Convert to PWM ticks and output.
        pwm_cfg.compare_a = servo_math::angle_to_ticks(current_pan);
        pwm_cfg.compare_b = servo_math::angle_to_ticks(current_tilt);
        pwm.set_config(&pwm_cfg);

        // Detect dispense trigger (rising edge on direction flags).
        // Only signal the dispenser task on the first tick that a valid
        // direction appears, and only if no sequence is already running.
        let dispense_direction = cmd.flags().dispense_direction();
        if !was_dispense_active && let Some(direction) = dispense_direction {
            let dispensing = critical_section::with(|cs| DISPENSING.borrow(cs).get());
            if !dispensing {
                DISPENSE_SIGNAL.signal(DispenseRequest {
                    direction,
                    tier: cmd.flags().dispense_tier(),
                });
            }
        }
        was_dispense_active = dispense_direction.is_some();
    }
}
