//! 200 Hz servo control loop.
//!
//! Reads the latest [`ServoCommand`](catlaser_common::ServoCommand) from shared
//! state, applies angle clamping, exponential interpolation, slew-rate limiting,
//! and outputs PWM to the pan/tilt servos at 200 Hz.

use embassy_rp::gpio::{Level, Output};
use embassy_rp::pwm::{self, Pwm};
use embassy_time::{Duration, Ticker};
use fixed::traits::ToFixed as _;

use catlaser_common::constants::{CONTROL_LOOP_HZ, PAN_HOME, PWM_DIVIDER, PWM_TOP, TILT_HOME};
use catlaser_common::servo_math;

use crate::state::LATEST_CMD;

/// 200 Hz servo interpolation task.
///
/// Maintains current pan/tilt angles (initialized to home) and smoothly
/// drives them toward the latest commanded target each tick. Outputs the
/// resulting angles as PWM compare values on slice 1 channels A (pan)
/// and B (tilt). Drives the laser GPIO from the command flags each tick.
#[embassy_executor::task]
pub async fn control_task(mut pwm: Pwm<'static>, mut laser: Output<'static>) {
    defmt::info!("control: starting 200Hz loop");

    let mut current_pan: i16 = PAN_HOME;
    let mut current_tilt: i16 = TILT_HOME;

    let mut pwm_cfg = pwm::Config::default();
    pwm_cfg.top = PWM_TOP;
    pwm_cfg.divider = PWM_DIVIDER.to_fixed();
    pwm_cfg.compare_a = servo_math::angle_to_ticks(current_pan);
    pwm_cfg.compare_b = servo_math::angle_to_ticks(current_tilt);

    let mut ticker = Ticker::every(Duration::from_hz(u64::from(CONTROL_LOOP_HZ)));

    loop {
        ticker.next().await;

        let cmd = critical_section::with(|cs| LATEST_CMD.borrow(cs).get());

        // Clamp targets to safe range.
        let target_pan = servo_math::clamp_pan(cmd.pan());
        let target_tilt = servo_math::clamp_tilt(cmd.tilt(), cmd.flags().person_detected());

        // Interpolate toward target.
        let next_pan = servo_math::interpolate(current_pan, target_pan, cmd.smoothing());
        let next_tilt = servo_math::interpolate(current_tilt, target_tilt, cmd.smoothing());

        // Apply slew rate limiting.
        current_pan = servo_math::slew_limit(current_pan, next_pan, cmd.max_slew());
        current_tilt = servo_math::slew_limit(current_tilt, next_tilt, cmd.max_slew());

        // Drive laser GPIO from command flags.
        laser.set_level(if cmd.flags().laser_on() {
            Level::High
        } else {
            Level::Low
        });

        // Convert to PWM ticks and output.
        pwm_cfg.compare_a = servo_math::angle_to_ticks(current_pan);
        pwm_cfg.compare_b = servo_math::angle_to_ticks(current_tilt);
        pwm.set_config(&pwm_cfg);
    }
}
