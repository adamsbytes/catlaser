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

mod control;
mod state;
mod uart;

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::pwm::Pwm;
use fixed::traits::ToFixed as _;

use catlaser_common::constants::{PAN_HOME, PWM_DIVIDER, PWM_TOP, TILT_HOME, UART_BAUD};
use catlaser_common::servo_math;

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
    let uart_rx = embassy_rp::uart::UartRx::new(p.UART0, p.PIN_1, Irqs, p.DMA_CH0, uart_config);

    if let Ok(token) = uart::uart_rx_task(uart_rx) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn uart_rx task");
        cortex_m::asm::udf();
    }

    // --- PWM: pan/tilt servos (GPIO2 = slice 1 ch A, GPIO3 = slice 1 ch B) ---
    let mut pwm_cfg = embassy_rp::pwm::Config::default();
    pwm_cfg.top = PWM_TOP;
    pwm_cfg.divider = PWM_DIVIDER.to_fixed();
    pwm_cfg.compare_a = servo_math::angle_to_ticks(PAN_HOME);
    pwm_cfg.compare_b = servo_math::angle_to_ticks(TILT_HOME);

    let pwm = Pwm::new_output_ab(p.PWM_SLICE1, p.PIN_2, p.PIN_3, pwm_cfg);

    if let Ok(token) = control::control_task(pwm) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn control task");
        cortex_m::asm::udf();
    }

    defmt::info!("catlaser-mcu: all tasks spawned");
}
