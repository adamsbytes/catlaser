//! ACCESSCTRL peripheral security configuration.
//!
//! Assigns individual RP2350 peripherals and GPIO pins to Secure or
//! Non-Secure domains. ACCESSCTRL operates independently of the SAU —
//! even though the SAU marks the entire peripheral region as Non-Secure,
//! ACCESSCTRL can restrict specific peripherals to Secure-only access.
//!
//! After configuration, the LOCK register is set to prevent any
//! Non-Secure code (including bugs or malicious firmware) from
//! modifying the security assignments.
//!
//! # Peripherals marked Secure
//!
//! - **Watchdog** — only Secure code can start, feed, or stop the watchdog
//! - **POWMAN** — Secure brownout detection and power management
//!
//! # GPIO pins marked Secure
//!
//! - **Pin 7 (laser)** — laser GPIO is hardware-inaccessible to NS code
//!
//! # Everything else
//!
//! All other peripherals (UART, PWM, ADC, timers, GPIO bank, pads, SPI,
//! I2C, resets, clocks, oscillators, PLLs, SIO, etc.) are marked fully
//! accessible from Non-Secure code so the Embassy application image can
//! operate normally.

use embassy_rp::pac;

use catlaser_common::trustzone::{ACCESS_FULL_NS, ACCESS_SECURE_ONLY, GPIO_NS_MASK};

/// Configures ACCESSCTRL peripheral and GPIO security assignments.
///
/// Must be called exactly once during Secure boot, after SAU
/// configuration and before launching the Non-Secure image.
pub fn configure() {
    let ac = pac::ACCESSCTRL;

    // --- GPIO security ---
    //
    // gpio_nsmask0 controls pins 0-31. Each bit: 1 = NS-accessible,
    // 0 = Secure-only. GPIO_NS_MASK has pin 7 (laser) cleared.
    ac.gpio_nsmask0().write_value(GPIO_NS_MASK);

    // --- Peripherals that NS code needs (Embassy application) ---

    let ns = pac::accessctrl::regs::Access(ACCESS_FULL_NS);

    // UART for command RX from compute module.
    ac.uart0().write_value(ns);
    ac.uart1().write_value(ns);

    // PWM for servo control (pan, tilt, dispenser).
    ac.pwm().write_value(ns);

    // ADC for VBUS voltage monitoring.
    ac.adc0().write_value(ns);

    // Timers for Embassy async runtime (embassy-time driver).
    ac.timer0().write_value(ns);
    ac.timer1().write_value(ns);

    // GPIO bank and pad control for all NS pins.
    ac.io_bank0().write_value(ns);
    ac.io_bank1().write_value(ns);
    ac.pads_bank0().write_value(ns);
    ac.pads_qspi().write_value(ns);

    // Resets controller — NS code needs to deassert peripheral resets.
    ac.resets().write_value(ns);

    // Clock, oscillator, and PLL configuration — needed for Embassy init.
    ac.clocks().write_value(ns);
    ac.xosc().write_value(ns);
    ac.rosc().write_value(ns);
    ac.pll_sys().write_value(ns);
    ac.pll_usb().write_value(ns);

    // Tick generators — needed for Embassy time driver.
    ac.ticks().write_value(ns);

    // System info and bus control — general infrastructure.
    ac.sysinfo().write_value(ns);
    ac.busctrl().write_value(ns);

    // SPI peripherals — available for NS use.
    ac.spi0().write_value(ns);
    ac.spi1().write_value(ns);

    // I2C peripherals — available for NS use.
    ac.i2c0().write_value(ns);
    ac.i2c1().write_value(ns);

    // DMA — needed by Embassy UART and ADC drivers.
    ac.dma().write_value(ns);

    // ROM and flash access — NS image reads from flash via XIP.
    ac.rom().write_value(ns);
    ac.xip_main().write_value(ns);
    ac.xip_ctrl().write_value(ns);
    ac.xip_qmi().write_value(ns);
    ac.xip_aux().write_value(ns);

    // PIO — available for NS use.
    ac.pio0().write_value(ns);
    ac.pio1().write_value(ns);
    ac.pio2().write_value(ns);

    // USB — available for NS use (debug, future features).
    ac.usbctrl().write_value(ns);

    // System config.
    ac.syscfg().write_value(ns);

    // OTP — available for NS read access.
    ac.otp().write_value(ns);

    // Test bus manager.
    ac.tbman().write_value(ns);

    // HSTX — available for NS use.
    ac.hstx().write_value(ns);

    // --- Peripherals that remain Secure ---

    let sec = pac::accessctrl::regs::Access(ACCESS_SECURE_ONLY);

    // Watchdog — only Secure code can start/feed/stop. NS feeds via
    // gateway function that validates invariants before forwarding.
    ac.watchdog().write_value(sec);

    // Power management — Secure brownout handler reads POWMAN directly.
    ac.powman().write_value(sec);

    // --- Lock ACCESSCTRL configuration ---
    //
    // Once locked, writes from the corresponding master are silently
    // ignored. Lock bits are one-way: set to 1, never clearable except
    // by full ACCESSCTRL reset.
    //
    // Lock DMA to prevent it from being used as a side-channel to reach
    // Secure peripherals. Core 1 is not locked because the Secure image
    // runs on core 0 only and core 1 may be used by NS code.
    ac.lock().write(|w| {
        w.set_dma(true);
    });

    defmt::info!("accessctrl: peripherals assigned, lock set");
}
