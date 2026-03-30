# ADR-005: Migrate MCU from RP2040 to RP2350 with TrustZone-M Safety Partitioning

## Status

Accepted

## Context

The catlaser product contains a Class 3R laser diode (5 mW, 650 nm) driven by MCU firmware. The RP2040 (Cortex-M0+) enforces all safety invariants — watchdog, tilt clamp, person-detection gating, power-loss kill — in software running in a single flat address space. Any firmware bug (buffer overflow in the UART parser, logic error in servo interpolation, off-by-one in command parsing) has the theoretical ability to corrupt safety state or write the laser GPIO directly, because no hardware boundary separates safety-critical code from application logic.

This matters for three reasons:

**Laser safety is a physical harm risk.** A Class 3R laser can cause retinal injury with direct eye exposure. The product operates autonomously in homes with children and pets. Safety interlocks must be robust against software defects, not just correct software.

**FDA compliance demands demonstrable interlocks.** 21 CFR 1040.10 requires laser products to have safety interlocks that prevent human access to laser radiation. The FDA product report must describe these interlocks and their failure modes. A hardware-enforced isolation boundary — where the laser GPIO is physically inaccessible to application code — is a materially stronger compliance argument than "the firmware is correct and tested." The ability to state that no Non-Secure code, including bugs, corrupted state, or hypothetical malicious firmware, can actuate the laser without passing through hardware-gated safety checks strengthens the product report.

**The RP2350 supports this at the same price point.** The RP2350 (dual Cortex-M33, ARMv8-M with TrustZone-M) is a direct replacement for the RP2040 at the same BOM cost (~$0.80). It provides:

- SAU (Security Attribution Unit) with 8 programmable regions for partitioning memory into Secure, Non-Secure, and Non-Secure Callable zones
- ACCESSCTRL for per-peripheral security attribution — GPIO pins, DMA channels, watchdog, each individually assignable to Secure or Non-Secure
- Hardware-enforced bus filtering — a Non-Secure bus transaction targeting Secure memory is rejected by silicon before reaching the target
- SecureFault exception on any isolation violation
- Banked registers (separate stacks, NVIC, SysTick per security state)

The RP2350 also brings 520 KB SRAM (vs 264 KB), dual cores, a higher default clock (150 MHz vs 125 MHz), and 12 PWM slices (vs 8) — all of which provide headroom for the two-image architecture without resource pressure. The additional flash/SRAM overhead of a small Secure image is negligible against these gains.

## Decision

Migrate the MCU from RP2040 to RP2350 and partition the firmware into two independent images using TrustZone-M:

**Secure image** (small, synchronous, no Embassy runtime):
- SAU and ACCESSCTRL initialization at boot
- Owns laser GPIO, watchdog peripheral, and tilt limit state
- Exposes NSC (Non-Secure Callable) gateway functions: `set_laser_state`, `report_tilt`, `feed_watchdog`, `report_person_detected`
- Secure interrupt handlers for watchdog timeout, tilt fault, and power brownout — all force laser off unconditionally
- Boots the Non-Secure image after partitioning is configured

**Non-Secure image** (Embassy async runtime, existing application logic):
- 200 Hz servo interpolation, UART parsing, dispenser control
- Calls Secure gateways to request laser state changes, report sensor data, and feed the watchdog
- Cannot access laser GPIO, watchdog, or tilt state directly — attempts trigger a hardware SecureFault

The Secure image is linked first, producing a veneer import library (`.o`). The Non-Secure image links against this to resolve gateway function addresses. Both images target `thumbv8m.main-none-eabi`.

## Consequences

- The laser GPIO becomes hardware-inaccessible to application firmware. A buffer overflow in UART parsing, a logic bug in servo interpolation, or deliberately malicious Non-Secure code cannot actuate the laser, disable the watchdog, or alter tilt limits.
- The FDA product report can cite hardware-enforced safety interlocks backed by silicon, not software correctness.
- A new workspace member (`catlaser-mcu-secure`) is required for the Secure image. The existing `catlaser-mcu` becomes the Non-Secure image, refactored to call gateway functions instead of driving laser GPIO and watchdog directly.
- `catlaser-common` gains NSC gateway function type signatures shared between both images.
- The build system gains a two-stage link: Secure image first (produces veneer library), then Non-Secure image (links against veneers). This requires build script or Makefile orchestration outside Cargo's normal workflow.
- The Secure image requires nightly Rust for `extern "C-cmse-nonsecure-entry"` (rust-lang/rust#75835) and the `arm-none-eabi-ld` linker for veneer generation (`rust-lld` does not yet produce CMSE import libraries).
- Enabling TrustZone on the RP2350 disables the Hazard3 RISC-V cores — Cortex-M33 must be selected at boot. No impact on this project (firmware already targets ARM).
- PWM timing constants require recalculation for the 150 MHz default clock (divider/top values change).
- The `memory.x` linker scripts must define Secure and Non-Secure flash/SRAM regions and the NSC veneer region.
