//! Hopper sensor monitoring and status LED driver.
//!
//! Runs as a dedicated Embassy task at [`HOPPER_POLL_HZ`]. Reads the IR
//! break-beam sensor on GPIO27 and drives the status LED on GPIO25 based
//! on the debounced hopper state.
//!
//! # Sensor convention
//!
//! The IR break-beam sensor at the hopper base:
//! - **Beam blocked** (treats present) → GPIO reads LOW
//! - **Beam clear** (hopper empty) → GPIO reads HIGH
//!
//! # LED behavior
//!
//! - **Treats present:** LED solid ON (normal operation)
//! - **Hopper empty:** LED blinks at 1 Hz (toggles each poll tick)
//! - **Power lost:** LED off (conserve supercap budget)

use embassy_rp::gpio::{Input, Level, Output};
use embassy_time::{Duration, Ticker};

use catlaser_common::HopperDebouncer;
use catlaser_common::constants::{HOPPER_DEBOUNCE_THRESHOLD, HOPPER_POLL_HZ};

use crate::state::{HOPPER_EMPTY, POWER_LOST};

/// Hopper sensor monitoring and status LED task.
///
/// Polls the IR break-beam sensor at [`HOPPER_POLL_HZ`], feeds readings
/// through a [`HopperDebouncer`], publishes the debounced state to
/// [`HOPPER_EMPTY`], and drives the status LED accordingly.
///
/// On power loss, the LED is turned off immediately to conserve supercap
/// energy for the compute module shutdown sequence.
#[embassy_executor::task]
pub async fn hopper_task(sensor: Input<'static>, mut led: Output<'static>) {
    defmt::info!(
        "hopper: starting ({}Hz, debounce={})",
        HOPPER_POLL_HZ,
        HOPPER_DEBOUNCE_THRESHOLD,
    );

    let mut debouncer = HopperDebouncer::new(HOPPER_DEBOUNCE_THRESHOLD);
    let mut led_on = false;
    let mut ticker = Ticker::every(Duration::from_hz(u64::from(HOPPER_POLL_HZ)));

    loop {
        ticker.next().await;

        // Power loss: kill LED and stop updating hopper state.
        // The supercap budget is for the compute module shutdown, not us.
        let power_lost = critical_section::with(|cs| POWER_LOST.borrow(cs).get());
        if power_lost {
            led.set_low();
            defmt::info!("hopper: power lost, LED off, task exiting");
            return;
        }

        // Read sensor: HIGH = beam clear = empty, LOW = beam blocked = present.
        let beam_clear = sensor.get_level() == Level::High;
        let is_empty = debouncer.update(beam_clear);

        // Publish debounced state.
        critical_section::with(|cs| HOPPER_EMPTY.borrow(cs).set(is_empty));

        // Drive LED.
        if is_empty {
            // Blink: toggle each tick (1 Hz at 2 Hz poll rate).
            led_on = !led_on;
            led.set_level(if led_on { Level::High } else { Level::Low });
        } else {
            // Solid ON: treats present, normal operation.
            led.set_high();
            led_on = true;
        }
    }
}
