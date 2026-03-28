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
//!   positions, outputs PWM
//! - `dispenser` — drives disc/door/deflector servos through timed dispense
//!   sequence on command, with jam detection and safety abort
//! - `watchdog` — monitors command freshness, kills laser and homes servos
//!   on timeout
//! - `power` — monitors VBUS via ADC at 10Hz, initiates shutdown on power
//!   loss (laser off, servos home, signal compute module)

#![no_std]
#![no_main]

mod control;
mod dispenser;
mod power;
mod safety;
mod state;
mod uart;

use embassy_executor::Spawner;
use embassy_rp::adc;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output, Pull};
use embassy_rp::pwm::Pwm;
use embassy_rp::watchdog::{ResetReason, Watchdog};
use fixed::traits::ToFixed as _;

use catlaser_common::constants::{
    DEFLECTOR_CENTER, DISC_CLOSED, DOOR_CLOSED, PAN_HOME, PWM_DIVIDER, PWM_TOP, TILT_HOME,
    UART_BAUD,
};
use catlaser_common::servo_math;

use {defmt_rtt as _, panic_probe as _};

bind_interrupts!(struct Irqs {
    UART0_IRQ => embassy_rp::uart::InterruptHandler<embassy_rp::peripherals::UART0>;
    DMA_IRQ_0 => embassy_rp::dma::InterruptHandler<embassy_rp::peripherals::DMA_CH0>,
                 embassy_rp::dma::InterruptHandler<embassy_rp::peripherals::DMA_CH1>;
    ADC_IRQ_FIFO => embassy_rp::adc::InterruptHandler;
});

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(embassy_rp::config::Config::default());

    defmt::info!("catlaser-mcu: starting");

    // --- Watchdog: check for previous reset reason ---
    let watchdog = Watchdog::new(p.WATCHDOG);
    match watchdog.reset_reason() {
        Some(ResetReason::Forced) => defmt::warn!("boot: previous forced reset"),
        Some(ResetReason::TimedOut) => defmt::warn!("boot: previous watchdog timeout"),
        None => {}
    }

    // --- UART: commands from compute module (RX), shutdown signal (TX) ---
    let mut uart_config = embassy_rp::uart::Config::default();
    uart_config.baudrate = UART_BAUD;
    let uart_full = embassy_rp::uart::Uart::new(
        p.UART0,
        p.PIN_0,
        p.PIN_1,
        Irqs,
        p.DMA_CH1,
        p.DMA_CH0,
        uart_config,
    );
    let (uart_tx, uart_rx) = uart_full.split();

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

    // --- Laser GPIO: default off, driven by control loop from command flags ---
    let laser = Output::new(p.PIN_7, Level::Low);

    if let Ok(token) = control::control_task(pwm, laser) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn control task");
        cortex_m::asm::udf();
    }

    // --- Dispenser PWM: disc (GPIO4), door (GPIO5), deflector (GPIO6) ---
    let mut dd_cfg = embassy_rp::pwm::Config::default();
    dd_cfg.top = PWM_TOP;
    dd_cfg.divider = PWM_DIVIDER.to_fixed();
    dd_cfg.compare_a = servo_math::angle_to_ticks(DISC_CLOSED);
    dd_cfg.compare_b = servo_math::angle_to_ticks(DOOR_CLOSED);
    let disc_door_pwm = Pwm::new_output_ab(p.PWM_SLICE2, p.PIN_4, p.PIN_5, dd_cfg);

    let mut defl_cfg = embassy_rp::pwm::Config::default();
    defl_cfg.top = PWM_TOP;
    defl_cfg.divider = PWM_DIVIDER.to_fixed();
    defl_cfg.compare_a = servo_math::angle_to_ticks(DEFLECTOR_CENTER);
    let deflector_pwm = Pwm::new_output_a(p.PWM_SLICE3, p.PIN_6, defl_cfg);

    if let Ok(token) = dispenser::dispenser_task(disc_door_pwm, deflector_pwm) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn dispenser task");
        cortex_m::asm::udf();
    }

    // --- Watchdog: software timeout + hardware backstop ---
    if let Ok(token) = safety::watchdog_task(watchdog) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn watchdog task");
        cortex_m::asm::udf();
    }

    // --- ADC + power monitor: VBUS voltage on GPIO26 / ADC0 ---
    let adc = adc::Adc::new(p.ADC, Irqs, adc::Config::default());
    let vbus_channel = adc::Channel::new_pin(p.PIN_26, Pull::None);

    if let Ok(token) = power::power_monitor_task(adc, vbus_channel, uart_tx) {
        spawner.spawn(token);
    } else {
        defmt::error!("catlaser-mcu: failed to spawn power_monitor task");
        cortex_m::asm::udf();
    }

    defmt::info!("catlaser-mcu: all tasks spawned");
}
