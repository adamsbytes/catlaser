//! UART receive task — reads [`ServoCommand`] frames from the compute module.
//!
//! Bytes arrive on UART0 RX at 115200 baud, 8-N-1. The task feeds them into
//! a [`FrameParser`] which handles framing and checksum validation, then
//! publishes valid commands to shared state for the control loop and watchdog.

use embassy_rp::uart;
use embassy_time::Instant;

use catlaser_common::FrameParser;

use crate::state::{LAST_RX_TICKS, LATEST_CMD};

/// UART receive task.
///
/// Reads bytes one at a time from the compute module via DMA, parses 8-byte
/// [`ServoCommand`] frames, and publishes valid commands to shared state.
/// Runs forever — only resets the parser on unrecoverable UART errors.
#[embassy_executor::task]
pub async fn uart_rx_task(mut rx: uart::UartRx<'static, uart::Async>) {
    defmt::info!("uart_rx: listening");

    let mut parser = FrameParser::new();
    let mut buf = [0_u8; 1_usize];

    loop {
        if let Err(e) = rx.read(&mut buf).await {
            defmt::warn!("uart_rx: read error: {}", e);
            parser.reset();
            continue;
        }

        let byte = buf[0_usize];

        if let Some(cmd) = parser.push(byte) {
            critical_section::with(|cs| {
                LATEST_CMD.borrow(cs).set(cmd);
                LAST_RX_TICKS.borrow(cs).set(Instant::now().as_ticks());
            });

            defmt::trace!(
                "uart_rx: pan={} tilt={} flags={:#04x}",
                cmd.pan(),
                cmd.tilt(),
                cmd.flags().raw(),
            );
        }
    }
}
