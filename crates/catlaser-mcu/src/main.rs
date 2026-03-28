//! Catlaser MCU firmware.
//!
//! 200Hz servo interpolation, laser GPIO, dispenser control, and watchdog
//! on RP2040 via Embassy async runtime.
//!
//! # Task architecture
//!
//! - `uart_rx` — receives 8-byte [`ServoCommand`] frames from the compute
//!   module, publishes to shared state
//! - `control` — 200Hz loop: reads latest command, interpolates servo
//!   positions, outputs PWM (future step)
//! - `watchdog` — monitors command freshness, kills laser and homes servos
//!   on timeout (future step)
//! - `power` — monitors VBUS via ADC, initiates shutdown on power loss
//!   (future step)

#![no_std]
#![no_main]

mod state;
mod uart;

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;

use catlaser_common::constants::UART_BAUD;

use {defmt_rtt as _, panic_probe as _};

bind_interrupts!(struct Irqs {
    UART0_IRQ => embassy_rp::uart::InterruptHandler<embassy_rp::peripherals::UART0>;
    DMA_IRQ_0 => embassy_rp::dma::InterruptHandler<embassy_rp::peripherals::DMA_CH0>;
});

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(embassy_rp::config::Config::default());

    defmt::info!("catlaser-mcu: starting");

    // --- UART RX: commands from compute module ---
    let mut uart_config = embassy_rp::uart::Config::default();
    uart_config.baudrate = UART_BAUD;
    let uart_rx = embassy_rp::uart::UartRx::new(
        p.UART0, p.PIN_1, Irqs, p.DMA_CH0, uart_config,
    );

    if let Ok(token) = uart::uart_rx_task(uart_rx) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn uart_rx task");
        cortex_m::asm::udf();
    }

    defmt::info!("catlaser-mcu: all tasks spawned");
}
