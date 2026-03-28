//! Safety watchdog — monitors command freshness and enforces safe state on timeout.
//!
//! Runs as a dedicated Embassy task at [`WATCHDOG_CHECK_HZ`]. Two independent
//! safety layers:
//!
//! 1. **Software watchdog**: compares [`LAST_RX_TICKS`](crate::state::LAST_RX_TICKS)
//!    against current time. When stale (>[`WATCHDOG_TIMEOUT_MS`] since last valid
//!    command, or no command ever received), forces [`ServoCommand::HOME`] into
//!    shared state — laser off, servos home.
//!
//! 2. **Hardware watchdog**: RP2040 watchdog peripheral, fed every tick to prove
//!    this task is alive. If the task itself hangs (firmware bug), the hardware
//!    watchdog resets the MCU, which boots into safe state by default initialization.

use embassy_rp::watchdog::Watchdog;
use embassy_time::{Duration, Instant, Ticker};

use catlaser_common::ServoCommand;
use catlaser_common::constants::{WATCHDOG_CHECK_HZ, WATCHDOG_TIMEOUT_MS, is_command_stale};

use crate::state::{LAST_RX_TICKS, LATEST_CMD};

/// Software + hardware watchdog task.
///
/// Checks command freshness at [`WATCHDOG_CHECK_HZ`] and forces safe state
/// when commands are stale. Feeds the RP2040 hardware watchdog every tick —
/// if this task hangs, the hardware watchdog resets the MCU after
/// [`WATCHDOG_TIMEOUT_MS`].
#[embassy_executor::task]
pub async fn watchdog_task(mut wd: Watchdog) {
    defmt::info!(
        "watchdog: starting (timeout={}ms, check={}Hz)",
        WATCHDOG_TIMEOUT_MS,
        WATCHDOG_CHECK_HZ,
    );

    // Pause hardware watchdog when a debugger halts the CPU to prevent
    // false resets while stepping through code.
    wd.pause_on_debug(true);

    let hw_timeout = Duration::from_millis(u64::from(WATCHDOG_TIMEOUT_MS));
    wd.start(hw_timeout);

    let timeout_ticks = hw_timeout.as_ticks();
    let mut ticker = Ticker::every(Duration::from_hz(u64::from(WATCHDOG_CHECK_HZ)));
    let mut was_timed_out = false;

    loop {
        ticker.next().await;

        // Feed hardware watchdog — proves this task is alive and scheduling.
        wd.feed(hw_timeout);

        let last_rx = critical_section::with(|cs| LAST_RX_TICKS.borrow(cs).get());
        let now = Instant::now().as_ticks();

        if is_command_stale(last_rx, now, timeout_ticks) {
            critical_section::with(|cs| {
                LATEST_CMD.borrow(cs).set(ServoCommand::HOME);
            });

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
