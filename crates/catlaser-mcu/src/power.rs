//! Power monitoring -- detects VBUS loss and initiates shutdown.
//!
//! Runs as a dedicated Embassy task at [`VBUS_POLL_HZ`]. Reads the VBUS
//! voltage divider on GPIO26 (ADC0) and compares against
//! [`VBUS_LOW_THRESHOLD_MV`]. On threshold breach: forces safe state
//! (laser off, servos home), sets the [`POWER_LOST`] flag, sends
//! [`SHUTDOWN_SIGNAL`] to the compute module via UART TX, then returns.
//!
//! After this task returns, the control loop continues enforcing
//! [`ServoCommand::HOME`] via the `POWER_LOST` latch, and the watchdog
//! keeps feeding the hardware watchdog, until the supercap drains and the
//! MCU loses power.

use embassy_rp::adc::{self, Adc};
use embassy_rp::uart::{self, UartTx};
use embassy_time::{Duration, Ticker};

use catlaser_common::ServoCommand;
use catlaser_common::constants::{
    SHUTDOWN_SIGNAL, VBUS_LOW_THRESHOLD_MV, VBUS_POLL_HZ, raw_to_vbus_mv,
};

use crate::state::{LATEST_CMD, POWER_LOST};

/// VBUS power monitor task.
///
/// Polls the VBUS ADC channel at [`VBUS_POLL_HZ`] and compares against the
/// low-voltage threshold. On breach:
///
/// 1. Forces [`ServoCommand::HOME`] (laser off, servos home)
/// 2. Latches [`POWER_LOST`] so the control loop ignores further commands
/// 3. Sends [`SHUTDOWN_SIGNAL`] over UART TX for compute module shutdown
/// 4. Returns (task exits; other tasks continue in safe state)
#[embassy_executor::task]
pub async fn power_monitor_task(
    mut adc: Adc<'static, adc::Async>,
    mut vbus_channel: adc::Channel<'static>,
    mut uart_tx: UartTx<'static, uart::Async>,
) {
    defmt::info!(
        "power: starting VBUS monitor ({}Hz, threshold={}mV)",
        VBUS_POLL_HZ,
        VBUS_LOW_THRESHOLD_MV,
    );

    let mut ticker = Ticker::every(Duration::from_hz(u64::from(VBUS_POLL_HZ)));

    loop {
        ticker.next().await;

        let Ok(raw) = adc.read(&mut vbus_channel).await else {
            defmt::warn!("power: ADC read failed, retrying next tick");
            continue;
        };

        let vbus_mv = raw_to_vbus_mv(raw);

        if vbus_mv < VBUS_LOW_THRESHOLD_MV {
            defmt::warn!(
                "power: VBUS low ({}mV < {}mV), initiating shutdown",
                vbus_mv,
                VBUS_LOW_THRESHOLD_MV,
            );

            // Force safe state and latch power-lost flag in a single
            // critical section to prevent any command from sneaking in.
            critical_section::with(|cs| {
                LATEST_CMD.borrow(cs).set(ServoCommand::HOME);
                POWER_LOST.borrow(cs).set(true);
            });

            // Kill laser via Secure gateway. Belt-and-suspenders with
            // the Secure POWMAN brownout handler.
            let _ = crate::gateway::laser_set(false);

            // Signal compute module to begin filesystem-safe shutdown.
            // Blocking write: one byte at 115200 baud = ~87 us, negligible
            // against the 5-8 second supercap budget.
            if let Err(e) = uart_tx.blocking_write(&[SHUTDOWN_SIGNAL]) {
                defmt::warn!("power: failed to send shutdown signal: {}", e);
            }
            if let Err(e) = uart_tx.blocking_flush() {
                defmt::warn!("power: failed to flush shutdown signal: {}", e);
            }

            defmt::info!("power: shutdown complete, task exiting");
            return;
        }
    }
}
