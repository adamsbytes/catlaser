//! TrustZone-M memory map and security partitioning constants.
//!
//! Shared between the Secure image (`catlaser-mcu-secure`) and Non-Secure
//! image (`catlaser-mcu`). Both linker scripts and both images must agree
//! on all region boundaries.
//!
//! # RP2350 resources
//!
//! - 2MB external QSPI flash at `0x1000_0000`
//! - 520KB on-die SRAM at `0x2000_0000`
//! - Peripherals at `0x4000_0000`+
//!
//! # SAU region alignment
//!
//! The ARMv8-M SAU requires region base addresses to be 32-byte aligned
//! and region limit addresses to satisfy `(limit & 0x1F) == 0x1F`. All
//! boundaries defined here satisfy these constraints with much coarser
//! (4KB+) alignment.

use crate::constants::PIN_LASER;

// ---------------------------------------------------------------------------
// Flash partitioning (2MB at 0x1000_0000)
// ---------------------------------------------------------------------------

/// First address of the flash XIP region.
pub const FLASH_BASE: u32 = 0x1000_0000_u32;

/// Total flash size in bytes (2MB).
pub const FLASH_SIZE: u32 = 0x0020_0000_u32;

/// Last address of the flash region (inclusive).
pub const FLASH_END: u32 = 0x101F_FFFF_u32;

/// Start of Secure flash (Secure image code + data).
pub const SECURE_FLASH_BASE: u32 = FLASH_BASE;

/// Size of the Secure flash region (64KB).
pub const SECURE_FLASH_SIZE: u32 = 0x0001_0000_u32;

/// Last address of the Secure flash region (inclusive).
pub const SECURE_FLASH_END: u32 = 0x1000_FFFF_u32;

/// Start of the NSC (Non-Secure Callable) veneer region.
///
/// This region contains `SG` + branch stubs — the only legal entry
/// points from Non-Secure into Secure code.
pub const NSC_FLASH_BASE: u32 = 0x1001_0000_u32;

/// Size of the NSC veneer region (256 bytes).
///
/// Enough for ~16 veneer stubs at 16 bytes each. The project needs
/// four gateways (`set_laser_state`, `report_tilt`, `feed_watchdog`,
/// `report_person_detected`).
pub const NSC_FLASH_SIZE: u32 = 0x0000_0100_u32;

/// Last address of the NSC veneer region (inclusive).
pub const NSC_FLASH_END: u32 = 0x1001_00FF_u32;

/// Start of Non-Secure flash (Embassy application image).
pub const NS_FLASH_BASE: u32 = 0x1001_0100_u32;

/// Size of the Non-Secure flash region.
pub const NS_FLASH_SIZE: u32 = 0x001E_FF00_u32;

/// Last address of the Non-Secure flash region (inclusive).
pub const NS_FLASH_END: u32 = FLASH_END;

// ---------------------------------------------------------------------------
// SRAM partitioning (520KB at 0x2000_0000)
// ---------------------------------------------------------------------------

/// First address of on-die SRAM.
pub const SRAM_BASE: u32 = 0x2000_0000_u32;

/// Total SRAM size in bytes (520KB).
pub const SRAM_SIZE: u32 = 0x0008_2000_u32;

/// Last address of SRAM (inclusive).
pub const SRAM_END: u32 = 0x2008_1FFF_u32;

/// Start of Secure SRAM (Secure image stack + data).
pub const SECURE_SRAM_BASE: u32 = SRAM_BASE;

/// Size of the Secure SRAM region (16KB).
pub const SECURE_SRAM_SIZE: u32 = 0x0000_4000_u32;

/// Last address of the Secure SRAM region (inclusive).
pub const SECURE_SRAM_END: u32 = 0x2000_3FFF_u32;

/// Start of Non-Secure SRAM (Embassy application data + stack).
pub const NS_SRAM_BASE: u32 = 0x2000_4000_u32;

/// Size of the Non-Secure SRAM region.
pub const NS_SRAM_SIZE: u32 = 0x0007_E000_u32;

/// Last address of the Non-Secure SRAM region (inclusive).
pub const NS_SRAM_END: u32 = SRAM_END;

// ---------------------------------------------------------------------------
// Peripheral region
// ---------------------------------------------------------------------------

/// Start of the peripheral address space.
pub const PERIPH_BASE: u32 = 0x4000_0000_u32;

/// Last address of the peripheral space marked NS by SAU (inclusive).
///
/// ACCESSCTRL further restricts individual peripherals within this
/// range to Secure-only access.
pub const PERIPH_END: u32 = 0x4FFF_FFFF_u32;

// ---------------------------------------------------------------------------
// GPIO security assignment
// ---------------------------------------------------------------------------

/// Bitmask of GPIO pins 0-31 accessible from Non-Secure code.
///
/// Every bit that is SET allows NS access. Bits that are CLEAR restrict
/// the pin to Secure-only access.
///
/// Pin 7 (laser) is Secure — its bit is cleared. All other used pins
/// (UART, PWM, ADC, sensor, LED) are Non-Secure.
pub const GPIO_NS_MASK: u32 = u32::MAX ^ (1_u32 << PIN_LASER);

// ---------------------------------------------------------------------------
// ACCESSCTRL register values for peripheral security
// ---------------------------------------------------------------------------

/// ACCESSCTRL `Access` register value for peripherals that Non-Secure
/// code (Embassy firmware) needs to use.
///
/// Allows access from both cores, DMA, and debugger at all
/// security/privilege levels.
///
/// Bits: NSU(0) | NSP(1) | SU(2) | SP(3) | CORE0(4) | CORE1(5) | DMA(6) | DBG(7)
pub const ACCESS_FULL_NS: u32 = 0xFF_u32;

/// ACCESSCTRL `Access` register value for peripherals that only
/// Secure code should access.
///
/// Allows access from both cores and debugger, but only at Secure
/// privilege levels. Non-Secure and DMA access denied.
///
/// Bits: SP(3) | CORE0(4) | CORE1(5) | DBG(7)
pub const ACCESS_SECURE_ONLY: u32 = 0b1011_1000_u32;

// ---------------------------------------------------------------------------
// SAU region indices
// ---------------------------------------------------------------------------

/// SAU region index for Non-Secure flash.
pub const SAU_REGION_NS_FLASH: u8 = 0_u8;

/// SAU region index for the NSC veneer region.
pub const SAU_REGION_NSC: u8 = 1_u8;

/// SAU region index for Non-Secure SRAM.
pub const SAU_REGION_NS_SRAM: u8 = 2_u8;

/// SAU region index for Non-Secure peripherals.
pub const SAU_REGION_NS_PERIPH: u8 = 3_u8;

/// Total number of SAU regions configured by the Secure image.
pub const SAU_REGION_COUNT: u8 = 4_u8;

/// Maximum SAU regions available on RP2350 (Cortex-M33).
pub const SAU_REGION_MAX: u8 = 8_u8;

// ---------------------------------------------------------------------------
// Gateway safety checking
// ---------------------------------------------------------------------------

/// Status codes returned by the Secure `set_laser_state` gateway.
///
/// Transmitted as `u32` over the CMSE ABI boundary. Zero indicates
/// success; non-zero values identify which safety invariant prevented
/// laser activation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[must_use]
pub enum GatewayStatus {
    /// Laser state change succeeded.
    Ok,
    /// Tilt angle exceeds the applicable horizon limit.
    TiltViolation,
    /// Hardware watchdog has not been started (NS firmware not ready).
    WatchdogInactive,
}

impl GatewayStatus {
    /// Raw `u32` value for transmission over the CMSE ABI.
    pub const fn to_raw(self) -> u32 {
        match self {
            Self::Ok => 0_u32,
            Self::TiltViolation => 1_u32,
            Self::WatchdogInactive => 2_u32,
        }
    }

    /// Converts a raw `u32` from the CMSE ABI to a status variant.
    ///
    /// Returns `None` for unrecognized values.
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            0_u32 => Some(Self::Ok),
            1_u32 => Some(Self::TiltViolation),
            2_u32 => Some(Self::WatchdogInactive),
            _ => None,
        }
    }

    /// Returns `true` if the status is [`Ok`](Self::Ok).
    pub const fn is_ok(self) -> bool {
        matches!(self, Self::Ok)
    }
}

/// Returns `true` if the given tilt pitch is within the applicable
/// horizon limit.
///
/// When `person_detected` is `true`, the stricter
/// [`TILT_HORIZON_LIMIT_PERSON`](crate::constants::TILT_HORIZON_LIMIT_PERSON)
/// is used. Positive tilt values point downward (safe); values below
/// the limit point upward toward eye height (unsafe).
pub const fn is_tilt_safe(tilt_pitch: i16, person_detected: bool) -> bool {
    let limit = if person_detected {
        crate::constants::TILT_HORIZON_LIMIT_PERSON
    } else {
        crate::constants::TILT_HORIZON_LIMIT
    };
    tilt_pitch >= limit
}

/// Checks whether laser activation is safe given the current tilt,
/// person-detection state, and watchdog status.
///
/// Returns [`GatewayStatus::Ok`] if all invariants pass. Invariants
/// are checked in priority order:
///
/// 1. **Watchdog active** -- the hardware safety net must be running
///    before the laser can turn on.
/// 2. **Tilt within bounds** -- the tilt pitch must be at or below the
///    applicable horizon limit (which tightens when a person is detected).
pub const fn check_laser_safety(
    tilt_pitch: i16,
    person_detected: bool,
    watchdog_active: bool,
) -> GatewayStatus {
    if !watchdog_active {
        return GatewayStatus::WatchdogInactive;
    }
    if !is_tilt_safe(tilt_pitch, person_detected) {
        return GatewayStatus::TiltViolation;
    }
    GatewayStatus::Ok
}

// ---------------------------------------------------------------------------
// Reset reason (watchdog diagnostics)
// ---------------------------------------------------------------------------

/// Reason for the most recent system reset, derived from the RP2350
/// `WATCHDOG.REASON` register.
///
/// Used by the Secure boot code to detect and log watchdog-triggered
/// resets. The reset reason is persisted in watchdog scratch register 0
/// for post-mortem analysis via SWD.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[must_use]
pub enum ResetReason {
    /// Normal power-on reset (neither watchdog bit set).
    PowerOn,
    /// Watchdog counter reached zero -- the Non-Secure firmware failed
    /// to call `feed_watchdog` within the timeout window.
    WatchdogTimeout,
    /// Software-initiated reset via `WATCHDOG.CTRL.TRIGGER`.
    WatchdogForced,
}

impl ResetReason {
    /// Decodes the RP2350 `WATCHDOG.REASON` register value.
    ///
    /// Register layout:
    /// - Bit 0 (`TIMER`): set if the watchdog timer expired
    /// - Bit 1 (`FORCE`): set if software triggered the reset
    ///
    /// `TIMER` takes precedence when both bits are set, because a
    /// genuine timeout is the more safety-relevant event.
    pub const fn from_watchdog_reason(bits: u32) -> Self {
        if bits & 0x01_u32 != 0_u32 {
            Self::WatchdogTimeout
        } else if bits & 0x02_u32 != 0_u32 {
            Self::WatchdogForced
        } else {
            Self::PowerOn
        }
    }
}

/// Watchdog scratch register index used by the Secure image to persist
/// the reset reason across watchdog-triggered resets.
///
/// Readable via SWD probe for post-mortem diagnostics. The Secure image
/// writes the raw `WATCHDOG.REASON` register value here on every boot.
pub const WATCHDOG_SCRATCH_RESET_REASON: usize = 0_usize;

// ---------------------------------------------------------------------------
// Compile-time invariants
// ---------------------------------------------------------------------------

// SAU region count must be within hardware limits.
const _: () = assert!(
    SAU_REGION_COUNT <= SAU_REGION_MAX,
    "configured SAU regions exceed hardware maximum of 8"
);

// SAU region indices must be unique and within bounds.
const _: () = assert!(
    SAU_REGION_NS_FLASH < SAU_REGION_COUNT,
    "NS flash SAU index out of bounds"
);
const _: () = assert!(
    SAU_REGION_NSC < SAU_REGION_COUNT,
    "NSC SAU index out of bounds"
);
const _: () = assert!(
    SAU_REGION_NS_SRAM < SAU_REGION_COUNT,
    "NS SRAM SAU index out of bounds"
);
const _: () = assert!(
    SAU_REGION_NS_PERIPH < SAU_REGION_COUNT,
    "NS periph SAU index out of bounds"
);
const _: () = assert!(
    SAU_REGION_NS_FLASH != SAU_REGION_NSC
        && SAU_REGION_NS_FLASH != SAU_REGION_NS_SRAM
        && SAU_REGION_NS_FLASH != SAU_REGION_NS_PERIPH
        && SAU_REGION_NSC != SAU_REGION_NS_SRAM
        && SAU_REGION_NSC != SAU_REGION_NS_PERIPH
        && SAU_REGION_NS_SRAM != SAU_REGION_NS_PERIPH,
    "SAU region indices must be unique"
);

// --- Flash partitioning ---

// Flash regions must be contiguous and cover the full 2MB.
const _: () = assert!(
    SECURE_FLASH_BASE == FLASH_BASE,
    "Secure flash must start at flash base"
);
const _: () = assert!(
    NSC_FLASH_BASE == SECURE_FLASH_END + 1,
    "NSC region must immediately follow Secure flash"
);
const _: () = assert!(
    NS_FLASH_BASE == NSC_FLASH_END + 1,
    "NS flash must immediately follow NSC region"
);
const _: () = assert!(
    NS_FLASH_END == FLASH_END,
    "NS flash must extend to end of physical flash"
);
const _: () = assert!(
    SECURE_FLASH_SIZE + NSC_FLASH_SIZE + NS_FLASH_SIZE == FLASH_SIZE,
    "flash regions must sum to total flash size"
);

// --- SRAM partitioning ---

// SRAM regions must be contiguous and cover the full 520KB.
const _: () = assert!(
    SECURE_SRAM_BASE == SRAM_BASE,
    "Secure SRAM must start at SRAM base"
);
const _: () = assert!(
    NS_SRAM_BASE == SECURE_SRAM_END + 1,
    "NS SRAM must immediately follow Secure SRAM"
);
const _: () = assert!(
    NS_SRAM_END == SRAM_END,
    "NS SRAM must extend to end of physical SRAM"
);
const _: () = assert!(
    SECURE_SRAM_SIZE + NS_SRAM_SIZE == SRAM_SIZE,
    "SRAM regions must sum to total SRAM size"
);

// --- SAU alignment (32-byte granularity) ---

// Base addresses must be 32-byte aligned (SAU requires low 5 bits zero).
const _: () = assert!(
    NS_FLASH_BASE.trailing_zeros() >= 5,
    "NS flash base must be 32-byte aligned"
);
const _: () = assert!(
    NSC_FLASH_BASE.trailing_zeros() >= 5,
    "NSC flash base must be 32-byte aligned"
);
const _: () = assert!(
    NS_SRAM_BASE.trailing_zeros() >= 5,
    "NS SRAM base must be 32-byte aligned"
);
const _: () = assert!(
    PERIPH_BASE.trailing_zeros() >= 5,
    "peripheral base must be 32-byte aligned"
);

// Limit addresses must have low 5 bits set (SAU limit address format).
const _: () = assert!(
    NS_FLASH_END & 0x1F == 0x1F,
    "NS flash end must satisfy SAU limit alignment"
);
const _: () = assert!(
    NSC_FLASH_END & 0x1F == 0x1F,
    "NSC flash end must satisfy SAU limit alignment"
);
const _: () = assert!(
    NS_SRAM_END & 0x1F == 0x1F,
    "NS SRAM end must satisfy SAU limit alignment"
);
const _: () = assert!(
    PERIPH_END & 0x1F == 0x1F,
    "peripheral end must satisfy SAU limit alignment"
);

// --- Region sizes must be non-zero ---

const _: () = assert!(
    SECURE_FLASH_SIZE > 0,
    "Secure flash region must be non-empty"
);
const _: () = assert!(NSC_FLASH_SIZE > 0, "NSC region must be non-empty");
const _: () = assert!(NS_FLASH_SIZE > 0, "NS flash region must be non-empty");
const _: () = assert!(SECURE_SRAM_SIZE > 0, "Secure SRAM region must be non-empty");
const _: () = assert!(NS_SRAM_SIZE > 0, "NS SRAM region must be non-empty");

// --- NSC must be within the Secure flash address range ---
// (The SAU marks it NSC, but it lives in the Secure image's flash space
// and is included in the Secure linker script.)

const _: () = assert!(
    NSC_FLASH_BASE >= SECURE_FLASH_BASE && NSC_FLASH_END <= SECURE_FLASH_END + NSC_FLASH_SIZE,
    "NSC region must be contiguous with Secure flash"
);

// --- GPIO security: laser pin must be Secure (bit cleared) ---

const _: () = assert!(
    GPIO_NS_MASK & (1_u32 << PIN_LASER) == 0,
    "laser GPIO pin must be Secure (bit cleared in GPIO_NS_MASK)"
);

// --- ACCESSCTRL register values must have SP (Secure Privileged) bit set ---

const _: () = assert!(
    ACCESS_SECURE_ONLY & 0x08 != 0,
    "ACCESS_SECURE_ONLY must allow Secure Privileged access"
);
const _: () = assert!(
    ACCESS_SECURE_ONLY.trailing_zeros() >= 2,
    "ACCESS_SECURE_ONLY must deny Non-Secure access"
);
const _: () = assert!(
    ACCESS_FULL_NS & 0x0F == 0x0F,
    "ACCESS_FULL_NS must allow all security/privilege levels"
);

// --- Gateway status codes ---

// Gateway status raw values must be distinct.
const _: () = assert!(
    GatewayStatus::Ok.to_raw() != GatewayStatus::TiltViolation.to_raw()
        && GatewayStatus::Ok.to_raw() != GatewayStatus::WatchdogInactive.to_raw()
        && GatewayStatus::TiltViolation.to_raw() != GatewayStatus::WatchdogInactive.to_raw(),
    "GatewayStatus raw values must be unique"
);

// Ok must be zero (C convention: 0 = success).
const _: () = assert!(
    GatewayStatus::Ok.to_raw() == 0_u32,
    "GatewayStatus::Ok must be 0"
);

// check_laser_safety must deny when watchdog is inactive.
const _: () = assert!(
    !check_laser_safety(crate::constants::TILT_HOME, false, false).is_ok(),
    "laser must be denied when watchdog is inactive"
);

// check_laser_safety must allow when all invariants pass.
const _: () = assert!(
    check_laser_safety(crate::constants::TILT_HOME, false, true).is_ok(),
    "laser must be allowed when all invariants pass"
);

// is_tilt_safe must accept the tilt home position.
const _: () = assert!(
    is_tilt_safe(crate::constants::TILT_HOME, false),
    "TILT_HOME must be safe without person detected"
);
const _: () = assert!(
    is_tilt_safe(crate::constants::TILT_HOME, true),
    "TILT_HOME must be safe with person detected"
);

// --- ResetReason ---

// Scratch register index must be valid (RP2350 has 8 scratch registers: 0-7).
const _: () = assert!(
    WATCHDOG_SCRATCH_RESET_REASON < 8,
    "WATCHDOG_SCRATCH_RESET_REASON must be a valid scratch register index (0-7)"
);

// Zero REASON register must decode as PowerOn.
const _: () = assert!(
    matches!(
        ResetReason::from_watchdog_reason(0_u32),
        ResetReason::PowerOn,
    ),
    "zero REASON register must decode as PowerOn"
);

// TIMER bit (bit 0) must decode as WatchdogTimeout.
const _: () = assert!(
    matches!(
        ResetReason::from_watchdog_reason(0x01_u32),
        ResetReason::WatchdogTimeout,
    ),
    "REASON bit 0 (TIMER) must decode as WatchdogTimeout"
);

// FORCE bit (bit 1) must decode as WatchdogForced.
const _: () = assert!(
    matches!(
        ResetReason::from_watchdog_reason(0x02_u32),
        ResetReason::WatchdogForced,
    ),
    "REASON bit 1 (FORCE) must decode as WatchdogForced"
);

// Both bits set: TIMER takes precedence over FORCE.
const _: () = assert!(
    matches!(
        ResetReason::from_watchdog_reason(0x03_u32),
        ResetReason::WatchdogTimeout,
    ),
    "both REASON bits set must decode as WatchdogTimeout (TIMER priority)"
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // --- Memory map arithmetic ---

    #[test]
    fn test_flash_end_matches_base_plus_size() {
        assert_eq!(
            FLASH_BASE
                .checked_add(FLASH_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(FLASH_END),
            "FLASH_END must equal FLASH_BASE + FLASH_SIZE - 1"
        );
    }

    #[test]
    fn test_sram_end_matches_base_plus_size() {
        assert_eq!(
            SRAM_BASE
                .checked_add(SRAM_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(SRAM_END),
            "SRAM_END must equal SRAM_BASE + SRAM_SIZE - 1"
        );
    }

    #[test]
    fn test_secure_flash_end_matches_base_plus_size() {
        assert_eq!(
            SECURE_FLASH_BASE
                .checked_add(SECURE_FLASH_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(SECURE_FLASH_END),
            "SECURE_FLASH_END must equal base + size - 1"
        );
    }

    #[test]
    fn test_nsc_flash_end_matches_base_plus_size() {
        assert_eq!(
            NSC_FLASH_BASE
                .checked_add(NSC_FLASH_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(NSC_FLASH_END),
            "NSC_FLASH_END must equal base + size - 1"
        );
    }

    #[test]
    fn test_ns_flash_end_matches_base_plus_size() {
        assert_eq!(
            NS_FLASH_BASE
                .checked_add(NS_FLASH_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(NS_FLASH_END),
            "NS_FLASH_END must equal base + size - 1"
        );
    }

    #[test]
    fn test_secure_sram_end_matches_base_plus_size() {
        assert_eq!(
            SECURE_SRAM_BASE
                .checked_add(SECURE_SRAM_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(SECURE_SRAM_END),
            "SECURE_SRAM_END must equal base + size - 1"
        );
    }

    #[test]
    fn test_ns_sram_end_matches_base_plus_size() {
        assert_eq!(
            NS_SRAM_BASE
                .checked_add(NS_SRAM_SIZE)
                .and_then(|v| v.checked_sub(1)),
            Some(NS_SRAM_END),
            "NS_SRAM_END must equal base + size - 1"
        );
    }

    // --- No overlap between flash regions (const-evaluated) ---

    const _: () = assert!(
        SECURE_FLASH_END < NSC_FLASH_BASE,
        "Secure flash must end before NSC starts"
    );
    const _: () = assert!(
        NSC_FLASH_END < NS_FLASH_BASE,
        "NSC must end before NS flash starts"
    );

    // --- No overlap between SRAM regions (const-evaluated) ---

    const _: () = assert!(
        SECURE_SRAM_END < NS_SRAM_BASE,
        "Secure SRAM must end before NS SRAM starts"
    );

    // --- GPIO NS mask ---

    #[test]
    fn test_gpio_ns_mask_laser_pin_secure() {
        let laser_bit = 1_u32.checked_shl(u32::from(PIN_LASER));
        assert_eq!(
            laser_bit.map(|b| GPIO_NS_MASK & b),
            Some(0_u32),
            "laser pin must be Secure (bit cleared)"
        );
    }

    #[test]
    fn test_gpio_ns_mask_other_pins_ns() {
        // All defined pins except the laser should be NS-accessible.
        for pin in [
            crate::constants::PIN_UART_TX,
            crate::constants::PIN_UART_RX,
            crate::constants::PIN_SERVO_PAN,
            crate::constants::PIN_SERVO_TILT,
            crate::constants::PIN_SERVO_DISC,
            crate::constants::PIN_SERVO_DOOR,
            crate::constants::PIN_SERVO_DEFLECTOR,
            crate::constants::PIN_STATUS_LED,
            crate::constants::PIN_VBUS_SENSE,
            crate::constants::PIN_HOPPER_SENSOR,
        ] {
            let bit = 1_u32.checked_shl(u32::from(pin));
            assert_eq!(
                bit.map(|b| GPIO_NS_MASK & b != 0),
                Some(true),
                "GPIO pin {pin} should be NS-accessible"
            );
        }
    }

    // --- ACCESSCTRL register values ---

    #[test]
    fn test_access_full_ns_all_bits_set() {
        assert_eq!(
            ACCESS_FULL_NS, 0xFF_u32,
            "ACCESS_FULL_NS must have all 8 access bits set"
        );
    }

    #[test]
    fn test_access_secure_only_denies_ns() {
        // NSU (bit 0) and NSP (bit 1) must be clear.
        assert_eq!(
            ACCESS_SECURE_ONLY & 0x03_u32,
            0_u32,
            "ACCESS_SECURE_ONLY must deny all Non-Secure access"
        );
    }

    #[test]
    fn test_access_secure_only_allows_secure_privileged() {
        // SP (bit 3) must be set.
        assert_ne!(
            ACCESS_SECURE_ONLY & 0x08_u32,
            0_u32,
            "ACCESS_SECURE_ONLY must allow Secure Privileged access"
        );
    }

    #[test]
    fn test_access_secure_only_allows_cores() {
        // CORE0 (bit 4) and CORE1 (bit 5) must be set.
        assert_ne!(
            ACCESS_SECURE_ONLY & 0x10_u32,
            0_u32,
            "ACCESS_SECURE_ONLY must allow core 0"
        );
        assert_ne!(
            ACCESS_SECURE_ONLY & 0x20_u32,
            0_u32,
            "ACCESS_SECURE_ONLY must allow core 1"
        );
    }

    // --- SAU alignment proptest ---

    /// Returns `true` if an address is a valid SAU region base (32-byte aligned).
    fn is_valid_sau_base(addr: u32) -> bool {
        addr == 0 || addr.trailing_zeros() >= 5
    }

    /// Returns `true` if an address is a valid SAU region limit (low 5 bits set).
    fn is_valid_sau_limit(addr: u32) -> bool {
        addr & 0x1F == 0x1F
    }

    proptest! {
        #[test]
        fn test_sau_base_alignment_implies_low_bits_zero(addr in any::<u32>()) {
            let aligned = addr & !0x1F_u32;
            prop_assert!(
                is_valid_sau_base(aligned),
                "masking low 5 bits must produce valid SAU base: 0x{:08x}",
                aligned,
            );
        }

        #[test]
        fn test_sau_limit_alignment_implies_low_bits_set(addr in any::<u32>()) {
            let aligned = addr | 0x1F_u32;
            prop_assert!(
                is_valid_sau_limit(aligned),
                "setting low 5 bits must produce valid SAU limit: 0x{:08x}",
                aligned,
            );
        }
    }

    // --- GatewayStatus ---

    #[test]
    fn test_gateway_status_ok_is_zero() {
        assert_eq!(
            GatewayStatus::Ok.to_raw(),
            0_u32,
            "Ok must be 0 (C convention)"
        );
    }

    #[test]
    fn test_gateway_status_round_trip_all_variants() {
        for status in [
            GatewayStatus::Ok,
            GatewayStatus::TiltViolation,
            GatewayStatus::WatchdogInactive,
        ] {
            assert_eq!(
                GatewayStatus::from_raw(status.to_raw()),
                Some(status),
                "round-trip failed for {status:?}"
            );
        }
    }

    #[test]
    fn test_gateway_status_from_raw_unknown() {
        for raw in [3_u32, 100_u32, u32::MAX] {
            assert_eq!(
                GatewayStatus::from_raw(raw),
                None,
                "unknown raw value {raw} must return None"
            );
        }
    }

    #[test]
    fn test_gateway_status_is_ok() {
        assert!(GatewayStatus::Ok.is_ok(), "Ok.is_ok() must be true");
        assert!(
            !GatewayStatus::TiltViolation.is_ok(),
            "TiltViolation.is_ok() must be false"
        );
        assert!(
            !GatewayStatus::WatchdogInactive.is_ok(),
            "WatchdogInactive.is_ok() must be false"
        );
    }

    // --- is_tilt_safe ---

    #[test]
    fn test_is_tilt_safe_at_normal_limit() {
        assert!(
            is_tilt_safe(crate::constants::TILT_HORIZON_LIMIT, false),
            "exactly at normal horizon limit must be safe"
        );
    }

    #[test]
    fn test_is_tilt_safe_below_normal_limit() {
        assert!(
            !is_tilt_safe(
                crate::constants::TILT_HORIZON_LIMIT.saturating_sub(1_i16),
                false,
            ),
            "one below normal horizon limit must be unsafe"
        );
    }

    #[test]
    fn test_is_tilt_safe_well_above_normal_limit() {
        assert!(
            is_tilt_safe(crate::constants::TILT_HOME, false),
            "home position must be safe without person"
        );
    }

    #[test]
    fn test_is_tilt_safe_at_person_limit() {
        assert!(
            is_tilt_safe(crate::constants::TILT_HORIZON_LIMIT_PERSON, true),
            "exactly at person horizon limit must be safe"
        );
    }

    #[test]
    fn test_is_tilt_safe_below_person_limit() {
        assert!(
            !is_tilt_safe(
                crate::constants::TILT_HORIZON_LIMIT_PERSON.saturating_sub(1_i16),
                true,
            ),
            "one below person horizon limit must be unsafe"
        );
    }

    #[test]
    fn test_is_tilt_safe_normal_valid_but_person_invalid() {
        // 0 is >= -1000 (safe without person) but < 500 (unsafe with person).
        assert!(is_tilt_safe(0_i16, false), "0 must be safe without person");
        assert!(!is_tilt_safe(0_i16, true), "0 must be unsafe with person");
    }

    // --- check_laser_safety ---

    #[test]
    fn test_check_laser_safety_all_good() {
        assert_eq!(
            check_laser_safety(crate::constants::TILT_HOME, false, true),
            GatewayStatus::Ok,
            "safe tilt + no person + watchdog active must be Ok"
        );
    }

    #[test]
    fn test_check_laser_safety_safe_with_person_and_safe_tilt() {
        assert_eq!(
            check_laser_safety(crate::constants::TILT_HOME, true, true),
            GatewayStatus::Ok,
            "safe tilt + person + watchdog active must be Ok"
        );
    }

    #[test]
    fn test_check_laser_safety_watchdog_inactive_highest_priority() {
        assert_eq!(
            check_laser_safety(crate::constants::TILT_HOME, false, false),
            GatewayStatus::WatchdogInactive,
            "watchdog inactive must take priority over safe state"
        );
    }

    #[test]
    fn test_check_laser_safety_watchdog_priority_over_tilt() {
        assert_eq!(
            check_laser_safety(i16::MIN, false, false),
            GatewayStatus::WatchdogInactive,
            "watchdog inactive must take priority over tilt violation"
        );
    }

    #[test]
    fn test_check_laser_safety_tilt_violation_no_person() {
        assert_eq!(
            check_laser_safety(
                crate::constants::TILT_HORIZON_LIMIT.saturating_sub(1_i16),
                false,
                true,
            ),
            GatewayStatus::TiltViolation,
            "tilt above normal horizon must be TiltViolation"
        );
    }

    #[test]
    fn test_check_laser_safety_tilt_violation_with_person() {
        // 0 is safe without person (>= -1000) but unsafe with person (< 500).
        assert_eq!(
            check_laser_safety(0_i16, true, true),
            GatewayStatus::TiltViolation,
            "tilt above person horizon must be TiltViolation"
        );
    }

    #[test]
    fn test_check_laser_safety_at_exact_normal_limit() {
        assert_eq!(
            check_laser_safety(crate::constants::TILT_HORIZON_LIMIT, false, true),
            GatewayStatus::Ok,
            "exactly at normal limit must be Ok"
        );
    }

    #[test]
    fn test_check_laser_safety_at_exact_person_limit() {
        assert_eq!(
            check_laser_safety(crate::constants::TILT_HORIZON_LIMIT_PERSON, true, true),
            GatewayStatus::Ok,
            "exactly at person limit must be Ok"
        );
    }

    // --- gateway safety proptest ---

    proptest! {
        #[test]
        fn test_is_tilt_safe_consistent_with_limit_comparison(
            tilt in any::<i16>(),
            person_detected in any::<bool>(),
        ) {
            let limit = if person_detected {
                crate::constants::TILT_HORIZON_LIMIT_PERSON
            } else {
                crate::constants::TILT_HORIZON_LIMIT
            };
            prop_assert_eq!(
                is_tilt_safe(tilt, person_detected),
                tilt >= limit,
                "is_tilt_safe({}, {}) must equal tilt >= limit({})",
                tilt, person_detected, limit,
            );
        }

        #[test]
        fn test_check_laser_safety_ok_iff_all_invariants_pass(
            tilt in any::<i16>(),
            person in any::<bool>(),
            wd_active in any::<bool>(),
        ) {
            let status = check_laser_safety(tilt, person, wd_active);
            let expected_ok = wd_active && is_tilt_safe(tilt, person);
            prop_assert_eq!(
                status.is_ok(),
                expected_ok,
                "check_laser_safety({}, {}, {}) = {:?}, expected ok = {}",
                tilt, person, wd_active, status, expected_ok,
            );
        }

        #[test]
        fn test_gateway_status_raw_round_trips(raw in 0_u32..=2_u32) {
            let status = GatewayStatus::from_raw(raw);
            prop_assert!(status.is_some(), "raw {} must be recognized", raw);
            if let Some(s) = status {
                prop_assert_eq!(
                    s.to_raw(),
                    raw,
                    "round-trip failed for raw {}",
                    raw,
                );
            }
        }

        #[test]
        fn test_gateway_status_unknown_raw_returns_none(raw in 3_u32..=u32::MAX) {
            prop_assert_eq!(
                GatewayStatus::from_raw(raw),
                None,
                "raw {} must return None",
                raw,
            );
        }

        #[test]
        fn test_is_tilt_safe_person_always_stricter(tilt in any::<i16>()) {
            // If unsafe without person, must also be unsafe with person.
            if !is_tilt_safe(tilt, false) {
                prop_assert!(
                    !is_tilt_safe(tilt, true),
                    "tilt {} unsafe without person must also be unsafe with person",
                    tilt,
                );
            }
        }
    }

    // --- ResetReason ---

    #[test]
    fn test_reset_reason_power_on() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0_u32),
            ResetReason::PowerOn,
            "zero bits must be PowerOn"
        );
    }

    #[test]
    fn test_reset_reason_watchdog_timeout() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0x01_u32),
            ResetReason::WatchdogTimeout,
            "bit 0 (TIMER) must be WatchdogTimeout"
        );
    }

    #[test]
    fn test_reset_reason_watchdog_forced() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0x02_u32),
            ResetReason::WatchdogForced,
            "bit 1 (FORCE) must be WatchdogForced"
        );
    }

    #[test]
    fn test_reset_reason_both_bits_timer_priority() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0x03_u32),
            ResetReason::WatchdogTimeout,
            "both bits set: TIMER takes priority over FORCE"
        );
    }

    #[test]
    fn test_reset_reason_high_bits_ignored() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0xFFFF_FFFC_u32),
            ResetReason::PowerOn,
            "only bits 0-1 should be examined"
        );
    }

    #[test]
    fn test_reset_reason_high_bits_with_timer() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0xFFFF_FFFD_u32),
            ResetReason::WatchdogTimeout,
            "high bits with TIMER set must still be WatchdogTimeout"
        );
    }

    #[test]
    fn test_reset_reason_high_bits_with_force() {
        assert_eq!(
            ResetReason::from_watchdog_reason(0xFFFF_FFFE_u32),
            ResetReason::WatchdogForced,
            "high bits with FORCE set (no TIMER) must be WatchdogForced"
        );
    }

    // --- ResetReason proptest ---

    proptest! {
        #[test]
        fn test_reset_reason_timer_bit_always_wins(bits in any::<u32>()) {
            let with_timer = bits | 0x01_u32;
            prop_assert_eq!(
                ResetReason::from_watchdog_reason(with_timer),
                ResetReason::WatchdogTimeout,
                "bit 0 set must always produce WatchdogTimeout, bits=0x{:08x}",
                with_timer,
            );
        }

        #[test]
        fn test_reset_reason_force_without_timer(bits in any::<u32>()) {
            let with_force_no_timer = (bits | 0x02_u32) & !0x01_u32;
            prop_assert_eq!(
                ResetReason::from_watchdog_reason(with_force_no_timer),
                ResetReason::WatchdogForced,
                "bit 1 set without bit 0 must produce WatchdogForced, bits=0x{:08x}",
                with_force_no_timer,
            );
        }

        #[test]
        fn test_reset_reason_no_low_bits_is_power_on(bits in any::<u32>()) {
            let no_low_bits = bits & !0x03_u32;
            prop_assert_eq!(
                ResetReason::from_watchdog_reason(no_low_bits),
                ResetReason::PowerOn,
                "bits 0-1 clear must produce PowerOn, bits=0x{:08x}",
                no_low_bits,
            );
        }
    }
}
