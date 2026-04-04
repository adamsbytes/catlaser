//! SAU (Security Attribution Unit) region configuration.
//!
//! Programs the Cortex-M33 SAU to partition memory into Secure,
//! Non-Secure, and Non-Secure Callable regions. All memory defaults
//! to Secure after reset; this module carves out NS and NSC regions
//! for the Embassy application image.
//!
//! # Regions configured
//!
//! | Index | Type | Range | Purpose |
//! |-------|------|-------|---------|
//! | 0 | NS | NS flash | Embassy application code |
//! | 1 | NSC | Veneer region | Secure gateway entry points |
//! | 2 | NS | NS SRAM | Embassy application data + stack |
//! | 3 | NS | Peripherals | Peripheral MMIO (ACCESSCTRL restricts individually) |

use cortex_m::peripheral::SAU;
use cortex_m::peripheral::sau::{SauRegion, SauRegionAttribute};

use catlaser_common::trustzone::{
    NS_FLASH_BASE, NS_FLASH_END, NS_SRAM_BASE, NS_SRAM_END, NSC_FLASH_BASE, NSC_FLASH_END,
    PERIPH_BASE, PERIPH_END, SAU_REGION_NS_FLASH, SAU_REGION_NS_PERIPH, SAU_REGION_NS_SRAM,
    SAU_REGION_NSC,
};

/// Configures the SAU with the catlaser memory partitioning and enables it.
///
/// Must be called exactly once during Secure boot, before launching the
/// Non-Secure image. After this function returns, all memory not explicitly
/// marked NS or NSC is Secure — including the Secure image's own flash
/// and SRAM.
pub fn configure(sau: &mut SAU) {
    // Region 0: Non-Secure flash (Embassy application code).
    sau.set_region(
        SAU_REGION_NS_FLASH,
        SauRegion {
            base_address: NS_FLASH_BASE,
            limit_address: NS_FLASH_END,
            attribute: SauRegionAttribute::NonSecure,
        },
    )
    .ok();

    // Region 1: Non-Secure Callable veneer region (gateway entry points).
    sau.set_region(
        SAU_REGION_NSC,
        SauRegion {
            base_address: NSC_FLASH_BASE,
            limit_address: NSC_FLASH_END,
            attribute: SauRegionAttribute::NonSecureCallable,
        },
    )
    .ok();

    // Region 2: Non-Secure SRAM (Embassy application data + stack).
    sau.set_region(
        SAU_REGION_NS_SRAM,
        SauRegion {
            base_address: NS_SRAM_BASE,
            limit_address: NS_SRAM_END,
            attribute: SauRegionAttribute::NonSecure,
        },
    )
    .ok();

    // Region 3: Non-Secure peripherals (ACCESSCTRL further restricts
    // individual peripherals like watchdog, POWMAN, and laser GPIO).
    sau.set_region(
        SAU_REGION_NS_PERIPH,
        SauRegion {
            base_address: PERIPH_BASE,
            limit_address: PERIPH_END,
            attribute: SauRegionAttribute::NonSecure,
        },
    )
    .ok();

    sau.enable();

    defmt::info!("sau: configured 4 regions, enabled");
}
