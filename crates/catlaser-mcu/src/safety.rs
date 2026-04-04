//! Safety watchdog — monitors command freshness and enforces safe state on timeout.
//!
//! Runs as a dedicated Embassy task at [`WATCHDOG_CHECK_HZ`]. Two independent
//! safety layers:
//!
//! 1. **Software watchdog**: compares [`LAST_RX_TICKS`](crate::state::LAST_RX_TICKS)
//!    against current time. When stale (>[`WATCHDOG_TIMEOUT_MS`] since last valid
//!    command, or no command ever received), forces [`ServoCommand::HOME`] into
//!    shared state and requests laser off via the Secure gateway.
//!
//! 2. **Hardware watchdog**: RP2350 watchdog peripheral, owned by the Secure
//!    world. Fed each tick through the [`feed_watchdog`](crate::gateway::watchdog_feed)
//!    gateway. If this task hangs (firmware bug), the hardware watchdog resets
//!    the MCU — the Secure handler forces the laser off before reset.

use embassy_time::{Duration, Instant, Ticker};

use catlaser_common::ServoCommand;
use catlaser_common::constants::{WATCHDOG_CHECK_HZ, WATCHDOG_TIMEOUT_MS, is_command_stale};

use crate::state::{LAST_RX_TICKS, LATEST_CMD};

/// Software + hardware watchdog task.
///
/// Checks command freshness at [`WATCHDOG_CHECK_HZ`] and forces safe state
/// when commands are stale. Feeds the RP2350 hardware watchdog through the
/// Secure gateway every tick — if this task hangs, the hardware watchdog
/// resets the MCU after [`WATCHDOG_TIMEOUT_MS`].
#[embassy_executor::task]
pub async fn watchdog_task() {
    defmt::info!(
        "watchdog: starting (timeout={}ms, check={}Hz)",
        WATCHDOG_TIMEOUT_MS,
        WATCHDOG_CHECK_HZ,
    );

    let timeout = Duration::from_millis(u64::from(WATCHDOG_TIMEOUT_MS));
    let timeout_ticks = timeout.as_ticks();
    let mut ticker = Ticker::every(Duration::from_hz(u64::from(WATCHDOG_CHECK_HZ)));
    let mut was_timed_out = false;

    loop {
        ticker.next().await;

        // Feed hardware watchdog through Secure gateway. The Secure side
        // audits safety invariants before feeding — if the laser is on
        // while the tilt violates limits, the laser is forced off.
        crate::gateway::watchdog_feed();

        let last_rx = critical_section::with(|cs| LAST_RX_TICKS.borrow(cs).get());
        let now = Instant::now().as_ticks();

        if is_command_stale(last_rx, now, timeout_ticks) {
            // Force safe state in shared state for the control loop.
            critical_section::with(|cs| {
                LATEST_CMD.borrow(cs).set(ServoCommand::HOME);
            });

            // Kill laser immediately via Secure gateway rather than
            // waiting for the next control loop tick to pick up HOME.
            let _ = crate::gateway::laser_set(false);

            if !was_timed_out {
                if last_rx == 0_u64 {
                    defmt::info!("watchdog: awaiting first command");
                } else {
                    defmt::warn!("watchdog: command timeout, entering safe state");
                }
                was_timed_out = true;
            }
        } else if was_timed_out {
            defmt::info!("watchdog: commands resumed");
            was_timed_out = false;
        }
    }
}
