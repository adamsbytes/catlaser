//! Catlaser RP2350 `TrustZone` Secure image.
//!
//! Small, synchronous firmware that runs first after reset in Secure
//! state. Partitions memory and peripherals via SAU and ACCESSCTRL,
//! then launches the Non-Secure Embassy application image.
//!
//! # Boot sequence
//!
//! 1. RP2350 ROM boots in Secure state, verifies `IMAGE_DEF`, jumps here
//! 2. SAU configured: NS flash, NSC veneer, NS SRAM, NS peripherals
//! 3. ACCESSCTRL configured: laser GPIO, watchdog, POWMAN -> Secure
//! 4. Laser GPIO driven LOW (safe default before NS handoff)
//! 5. Gateway state initialized (safe defaults, watchdog deferred)
//! 6. Fault exceptions enabled (`SecureFault`, `UsageFault`, `BusFault`, `MemManage`)
//! 7. Secure handlers initialized (reset reason, POWMAN brownout armed)
//! 8. NS vector table and stack pointer loaded from NS flash
//! 9. Branch to NS reset handler (Embassy firmware)
//!
//! # Safety architecture
//!
//! After this image runs, the laser GPIO is hardware-inaccessible to
//! Non-Secure code. No firmware bug, buffer overflow, or malicious NS
//! code can actuate the laser without passing through Secure gateway
//! functions that validate all safety invariants before toggling the
//! laser. Every Secure exception and interrupt handler unconditionally
//! kills the laser before doing anything else.

#![no_std]
#![no_main]
// ADR-005: the Secure image requires nightly for the CMSE ABI
// (rust-lang/rust#75835). The Non-Secure image compiles on stable.
#![feature(cmse_nonsecure_entry)]
// The Secure image performs direct register writes to SAU, ACCESSCTRL, GPIO,
// and SCB_NS hardware. This is inherent to hardware security partitioning
// and justified by ADR-005 (TrustZone migration). Every unsafe block has a
// SAFETY comment documenting why the operation is sound.
#![expect(
    unsafe_code,
    reason = "bare-metal TrustZone partitioning requires direct register access (ADR-005)"
)]

mod accessctrl;
pub mod gateway;
mod handlers;
mod sau;

use catlaser_common::constants::PIN_LASER;
use catlaser_common::trustzone::{NS_FLASH_BASE, NS_SRAM_BASE};

use {defmt_rtt as _, panic_probe as _};

/// Bit mask for the laser GPIO pin (compile-time constant).
const LASER_PIN_MASK: u32 = 1_u32 << PIN_LASER;

/// Sets the laser GPIO pin as output LOW (Secure-owned, safe default).
///
/// Uses the RP2350 SIO and pad registers directly because the laser
/// GPIO is Secure — embassy-rp's GPIO driver is not used here.
fn laser_safe_default() {
    let io_bank = embassy_rp::pac::IO_BANK0;
    let pads = embassy_rp::pac::PADS_BANK0;
    let sio = embassy_rp::pac::SIO;

    let pin = usize::from(PIN_LASER);

    // Configure pad: output enable, disable input, no pull.
    pads.gpio(pin).write(|w| {
        w.set_ie(false);
        w.set_od(false);
        w.set_pue(false);
        w.set_pde(false);
    });

    // Select SIO function (function 5) for this GPIO.
    io_bank.gpio(pin).ctrl().write(|w| {
        w.set_funcsel(5_u8);
    });

    // Drive output LOW via SIO. Bank 0 covers GPIO 0-31.
    sio.gpio_oe(0).value_set().write_value(LASER_PIN_MASK);
    sio.gpio_out(0).value_clr().write_value(LASER_PIN_MASK);

    defmt::info!("laser: GPIO{} driven LOW (safe default)", PIN_LASER);
}

/// Launches the Non-Secure image by setting up its vector table and
/// stack pointer, then branching to its reset handler.
///
/// # Safety
///
/// The caller must ensure that:
/// - SAU and ACCESSCTRL are fully configured
/// - A valid Non-Secure image exists at `NS_FLASH_BASE`
/// - The NS vector table at `NS_FLASH_BASE` contains a valid initial
///   SP (word 0) and reset vector (word 1)
#[expect(
    clippy::as_conversions,
    reason = "u32-to-usize for hardware addresses on 32-bit ARM where they are identical; \
              From<u32> for usize is not provided because usize can be 16-bit on other targets"
)]
unsafe fn boot_ns() -> ! {
    let ns_vt: *const u32 = core::ptr::without_provenance(NS_FLASH_BASE as usize);

    // SAFETY: Word 0 of the NS vector table is the initial stack pointer.
    let ns_msp = unsafe { core::ptr::read_volatile(ns_vt) };

    // SAFETY: Offset 1 word (4 bytes) from the vector table base is safe
    // because the vector table occupies the entire first page of NS flash.
    let ns_reset_addr = unsafe { ns_vt.add(1) };
    // SAFETY: Word 1 of the NS vector table is the reset handler address.
    let ns_reset = unsafe { core::ptr::read_volatile(ns_reset_addr) };

    // SCB_NS->VTOR: set the Non-Secure vector table address.
    let scb_ns_vtor: *mut u32 = core::ptr::without_provenance_mut(0xE002_ED08_usize);
    // SAFETY: SCB_NS VTOR (0xE002_ED08) is the architecturally-defined
    // NS vector table register, writable only from Secure state.
    // NS_FLASH_BASE is 32-byte aligned and within NS flash.
    unsafe { core::ptr::write_volatile(scb_ns_vtor, NS_FLASH_BASE) };

    // SAFETY: ns_msp was read from the NS vector table and points to the
    // top of NS SRAM. write_ns writes to the MSP_NS register.
    unsafe { cortex_m::register::msp::write_ns(ns_msp) };

    // SCB_NS->MSPLIM: set the NS MSP limit to catch stack overflow.
    let scb_ns_msplim: *mut u32 = core::ptr::without_provenance_mut(0xE002_ED10_usize);
    // SAFETY: SCB_NS MSPLIM (0xE002_ED10) is writable only from Secure
    // state. NS_SRAM_BASE limits the NS stack to prevent silent corruption.
    unsafe { core::ptr::write_volatile(scb_ns_msplim, NS_SRAM_BASE) };

    defmt::info!(
        "boot_ns: VTOR=0x{:08x} MSP=0x{:08x} reset=0x{:08x}",
        NS_FLASH_BASE,
        ns_msp,
        ns_reset,
    );

    // Branch to Non-Secure reset handler. The LSB must be cleared to
    // indicate a Non-Secure target — the processor transitions to NS
    // state on the branch.
    let ns_entry = ns_reset & !1_u32;
    // SAFETY: ns_entry is the NS reset vector (with bit 0 cleared for NS
    // branch target). transmute converts the address to a function pointer.
    // This is the standard bare-metal pattern for jumping to an image at
    // a runtime-determined address.
    let ns_reset_fn: unsafe extern "C-unwind" fn() -> ! = unsafe { core::mem::transmute(ns_entry) };
    // SAFETY: All Secure initialization is complete (SAU, ACCESSCTRL,
    // laser safe default). The NS image at this address was flashed by
    // the build system and contains a valid reset handler.
    unsafe { ns_reset_fn() }
}

#[cortex_m_rt::entry]
fn main() -> ! {
    defmt::info!("catlaser-mcu-secure: Secure boot starting");

    let mut cp = cortex_m::Peripherals::take().unwrap_or_else(|| {
        defmt::error!("failed to take core peripherals");
        cortex_m::asm::udf();
    });

    // 1. Configure SAU — partition memory into S/NS/NSC.
    sau::configure(&mut cp.SAU);

    // 2. Configure ACCESSCTRL — assign peripherals to S/NS.
    accessctrl::configure();

    // 3. Force laser GPIO LOW before handing off to NS.
    laser_safe_default();

    // 4. Initialize gateway state (safe defaults, watchdog deferred).
    gateway::init();

    // 5. Enable SecureFault, UsageFault, BusFault, MemManage at
    //    Secure level so violations produce precise exceptions
    //    rather than escalating to HardFault.
    cp.SCB
        .enable(cortex_m::peripheral::scb::Exception::SecureFault);
    cp.SCB
        .enable(cortex_m::peripheral::scb::Exception::UsageFault);
    cp.SCB
        .enable(cortex_m::peripheral::scb::Exception::BusFault);
    cp.SCB
        .enable(cortex_m::peripheral::scb::Exception::MemoryManagement);

    // 6. Initialize Secure interrupt/exception handlers
    //    (reset reason check, POWMAN brownout detection).
    handlers::init();

    defmt::info!("catlaser-mcu-secure: launching Non-Secure image");

    // 7. Branch to the Non-Secure image — does not return.
    // SAFETY: SAU and ACCESSCTRL are fully configured, laser is safe,
    // and the NS image at NS_FLASH_BASE was flashed by the build system.
    unsafe { boot_ns() }
}
