//! Secure interrupt and exception handlers.
//!
//! Every exception and interrupt handler in the Secure image forces the
//! laser off unconditionally before doing anything else. This is the
//! safety invariant: any unexpected Secure-side event kills the laser
//! immediately, regardless of cause.
//!
//! # Exception handlers
//!
//! | Exception | Cause | Action |
//! |-----------|-------|--------|
//! | `HardFault` | Unrecoverable error | Laser off, halt |
//! | `SecureFault` | NS violated Secure boundary | Laser off, halt |
//! | `BusFault` | Invalid bus transaction | Laser off, halt |
//! | `UsageFault` | Undefined instruction / alignment | Laser off, halt |
//! | `MemoryManagement` | MPU violation | Laser off, halt |
//! | `DefaultHandler` | Unhandled interrupt | Laser off, halt |
//!
//! # Interrupt handlers
//!
//! | Interrupt | Source | Action |
//! |-----------|--------|--------|
//! | `POWMAN_IRQ_POW` | POWMAN brownout (VREG output low) | Laser off, disable source |
//!
//! # Boot-time initialization
//!
//! [`init`] checks the previous reset reason (watchdog timeout vs.
//! normal power-on) and configures the POWMAN brownout interrupt.
//! The interrupt targets Secure state by default (`NVIC_ITNS` is
//! all-zero after reset).

use cortex_m::peripheral::NVIC;
use embassy_rp::pac;
// Required by the `#[cortex_m_rt::interrupt]` macro for interrupt name
// verification at compile time.
use embassy_rp::pac::interrupt;

use catlaser_common::trustzone::ResetReason;

use crate::gateway;

// ---------------------------------------------------------------------------
// POWMAN brownout interrupt
// ---------------------------------------------------------------------------

/// POWMAN power interrupt (RP2350 IRQ #44).
///
/// Minimal type implementing [`InterruptNumber`](cortex_m::interrupt::InterruptNumber)
/// for NVIC enable/disable. Uses the hardware interrupt number from
/// the RP2350 datasheet (Section 4.4, Table 405).
#[derive(Debug, Clone, Copy)]
struct PowmanIrqPow;

/// RP2350 interrupt number for `POWMAN_IRQ_POW`.
const POWMAN_IRQ_NUM: u16 = 44_u16;

// Interrupt number must be within the RP2350 NVIC range (0-51).
const _: () = assert!(
    POWMAN_IRQ_NUM <= 51_u16,
    "POWMAN_IRQ_NUM must be a valid RP2350 interrupt number (0-51)"
);

// SAFETY: Interrupt number 44 is POWMAN_IRQ_POW on the RP2350, as
// defined in the RP2350 datasheet (Section 4.4, Table 405). This
// value is fixed in silicon and cannot change at runtime.
unsafe impl cortex_m::interrupt::InterruptNumber for PowmanIrqPow {
    fn number(self) -> u16 {
        POWMAN_IRQ_NUM
    }
}

// ---------------------------------------------------------------------------
// Boot-time initialization
// ---------------------------------------------------------------------------

/// Initializes Secure interrupt handlers and checks reset reason.
///
/// Must be called during Secure boot, after ACCESSCTRL configuration
/// (POWMAN must be Secure-assigned) and after gateway state init.
///
/// 1. Reads `WATCHDOG.REASON` to detect watchdog-triggered resets
/// 2. Persists reset reason in scratch register 0 for SWD diagnostics
/// 3. Enables POWMAN brownout interrupt (Secure-targeted)
pub fn init() {
    check_reset_reason();
    configure_brownout_interrupt();
    defmt::info!("handlers: initialized, brownout interrupt armed");
}

/// Reads the watchdog `REASON` register to determine if the previous
/// reset was caused by a watchdog timeout or software trigger.
///
/// Stores the raw reason in scratch register 0 for post-mortem
/// diagnostics via SWD probe.
fn check_reset_reason() {
    let wd = pac::WATCHDOG;

    let reason_raw = wd.reason().read().0;
    let reason = ResetReason::from_watchdog_reason(reason_raw);

    // Persist raw register value in scratch register 0 for SWD diagnostics.
    // WATCHDOG_SCRATCH_RESET_REASON documents which scratch register is used;
    // the PAC exposes individual methods (scratch0..scratch7), not an array.
    wd.scratch0().write_value(reason_raw);

    match reason {
        ResetReason::WatchdogTimeout => {
            defmt::warn!(
                "handlers: previous reset was WATCHDOG TIMEOUT (reason=0x{:08x})",
                reason_raw,
            );
        }
        ResetReason::WatchdogForced => {
            defmt::info!(
                "handlers: previous reset was software-triggered (reason=0x{:08x})",
                reason_raw,
            );
        }
        ResetReason::PowerOn => {
            defmt::info!("handlers: normal power-on reset");
        }
    }
}

/// Configures the POWMAN brownout detection interrupt.
///
/// The RP2350 BOD (Brown-Out Detector) monitors the core voltage
/// regulator output (DVDD). When DVDD drops below the BOD threshold,
/// `POWMAN_IRQ_POW` fires. Since `NVIC_ITNS` defaults to all-zero
/// after reset, this interrupt targets Secure state.
///
/// The BOD itself is enabled by default on RP2350. This function
/// only enables the interrupt routing.
fn configure_brownout_interrupt() {
    // Enable VREG_OUTPUT_LOW interrupt source in POWMAN.
    pac::POWMAN.inte().modify(|w| {
        w.set_vreg_output_low(true);
    });

    // SAFETY: The POWMAN_IRQ_POW handler is defined in this module
    // and linked into the Secure vector table by cortex-m-rt. The
    // interrupt targets Secure state (NVIC_ITNS bit 44 is 0 after
    // reset). Enabling it is safe because the handler is ready.
    unsafe {
        NVIC::unmask(PowmanIrqPow);
    }
}

// ---------------------------------------------------------------------------
// Exception handlers
// ---------------------------------------------------------------------------
//
// All fault handlers force the laser off and halt. The running
// watchdog (if active) resets the chip within 500ms for recovery.
// If the watchdog is not yet active (fault during Secure boot),
// the system is safe -- laser is off -- until power cycled.

/// Secure `HardFault` handler. Forces laser off on any unrecoverable error.
#[cortex_m_rt::exception]
unsafe fn HardFault(_frame: &cortex_m_rt::ExceptionFrame) -> ! {
    gateway::force_laser_off();
    defmt::error!("SECURE HARDFAULT — laser killed");
    loop {
        cortex_m::asm::wfi();
    }
}

/// Fires when Non-Secure code attempts to access Secure memory or
/// peripherals. Forces laser off -- a `TrustZone` violation indicates
/// a serious firmware defect.
#[cortex_m_rt::exception]
fn SecureFault() {
    gateway::force_laser_off();
    defmt::error!("SECUREFAULT — NS violated Secure boundary, laser killed");
    loop {
        cortex_m::asm::wfi();
    }
}

/// Fires on invalid bus transactions. Forces laser off.
#[cortex_m_rt::exception]
fn BusFault() {
    gateway::force_laser_off();
    defmt::error!("BUSFAULT — laser killed");
    loop {
        cortex_m::asm::wfi();
    }
}

/// Fires on undefined instructions or alignment faults. Forces laser off.
#[cortex_m_rt::exception]
fn UsageFault() {
    gateway::force_laser_off();
    defmt::error!("USAGEFAULT — laser killed");
    loop {
        cortex_m::asm::wfi();
    }
}

/// Fires on MPU access violations. Forces laser off.
#[cortex_m_rt::exception]
fn MemoryManagement() {
    gateway::force_laser_off();
    defmt::error!("MEMMANAGE — laser killed");
    loop {
        cortex_m::asm::wfi();
    }
}

/// Catch-all for any unhandled Secure interrupt. Forces laser off.
#[cortex_m_rt::exception]
unsafe fn DefaultHandler(irqn: i16) {
    gateway::force_laser_off();
    defmt::error!("UNHANDLED IRQ {} — laser killed", irqn);
    loop {
        cortex_m::asm::wfi();
    }
}

// ---------------------------------------------------------------------------
// Peripheral interrupt handlers
// ---------------------------------------------------------------------------

/// POWMAN brownout handler. Forces laser off when the core voltage
/// regulator output drops below the BOD threshold.
///
/// One-shot: after killing the laser, the interrupt source is disabled
/// in POWMAN to prevent continuous re-entry. The brownout condition
/// is terminal -- the supercap is discharging and the Non-Secure
/// `power_monitor_task` handles graceful shutdown via ADC polling.
#[cortex_m_rt::interrupt]
fn POWMAN_IRQ_POW() {
    gateway::force_laser_off();
    defmt::warn!("POWMAN: brownout (VREG output low) — laser killed");

    // Disable the interrupt source to prevent continuous re-entry.
    pac::POWMAN.inte().modify(|w| {
        w.set_vreg_output_low(false);
    });
}
