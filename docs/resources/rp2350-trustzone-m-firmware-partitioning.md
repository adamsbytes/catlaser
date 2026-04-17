# RP2350 TrustZone-M: Secure/Non-Secure Firmware Partitioning

## Overview

The RP2350's dual Cortex-M33 cores implement Arm's TrustZone-M security extension (ARMv8-M). This partitions the processor into two hardware-enforced worlds — Secure (S) and Non-Secure (NS) — where isolation is enforced at the bus fabric level, not by software permission checks. A Non-Secure bus transaction targeting Secure memory is rejected by hardware before it reaches the target; no amount of NS-side code — buggy or malicious — can circumvent this.

For the catlaser project, TrustZone-M lets the Secure world own all safety-critical invariants (laser kill, watchdog, beam-dwell cap derived from direct PWM compare register reads) while the Non-Secure world runs the application logic (servo interpolation, UART parsing, dispenser control) under Embassy. The Secure world takes no safety observables from Non-Secure — it samples the pan/tilt PWM compare registers itself, so NS cannot lie about beam position.

## RP2350-Specific TrustZone Resources

The RP2350 exposes the standard ARMv8-M Mainline security primitives plus Raspberry Pi's own bus-level extensions:

**Processor-level (per Cortex-M33 core):**

- 8 SAU (Security Attribution Unit) regions — programmable by Secure firmware to classify memory ranges as Secure, Non-Secure, or Non-Secure Callable (NSC).
- 8 Secure MPU regions and 8 Non-Secure MPU regions — independent memory protection for each world.
- Banked registers — separate MSP, PSP, SCB, SysTick, and NVIC instances for each security state. The core automatically switches register banks on world transitions.
- SecureFault exception — fires when NS code attempts to access S memory or violates a transition rule.

**Chip-level (RP2350 ACCESSCTRL):**

- Individual GPIO pins assignable to security domains.
- DMA channels individually assignable to Secure or Non-Secure, preventing NS code from using DMA as a side-channel to reach Secure peripherals.
- Global bus filtering based on the requesting master's security/privilege level, applied at the AHB5 bus fabric.
- ACCESSCTRL registers govern per-peripheral security attribution for the watchdog, GPIO, SRAM banks, flash (XIP), power management, clocks, PLLs, SHA-256 accelerator, TRNG, and more.
- ACCESSCTRL writes are themselves access-controlled and lockable via a LOCK register.

**Key constraint:** enabling TrustZone on the RP2350 disables the Hazard3 RISC-V cores, since they lack SAU/TrustZone support and would otherwise be an attack vector. The Cortex-M33 cores must be selected at boot.

**SDK status:** as of the RP2350 security white paper (November 2025), there is no high-level SDK API for configuring ACCESSCTRL or SAU partitioning — all setup must be done at the register level by the Secure image.

## How TrustZone-M Isolation Works

### Memory Attribution

When TrustZone is enabled, the processor starts in Secure state after reset and all memory defaults to Secure. The Secure boot code then programs the SAU (and optionally the chip's IDAU — Implementation-Defined Attribution Unit) to carve out regions with one of three attributes:

- **Secure (S):** accessible only from Secure state. This is where safety-critical code and data live.
- **Non-Secure (NS):** accessible from both states. This is where the Embassy application image, its RAM, and its peripherals reside.
- **Non-Secure Callable (NSC):** a small Secure region containing gateway veneers — the only legal entry points from NS into S code.

The security state of the processor is determined by the address of the instruction it is currently executing: code fetched from an NS region runs in NS state, code fetched from S or NSC runs in S state.

### World Transitions

**NS → S (Secure function call):** NS code calls a veneer address in the NSC region. The veneer's first instruction must be `SG` (Secure Gateway), which transitions the core to Secure state. The `SG` instruction then branches to the actual Secure function implementation in S memory. Any attempt to branch into Secure memory without going through an NSC veneer containing `SG` triggers a SecureFault.

**S → NS (return or callback):** Secure code returns to NS via the `BXNS LR` instruction, which branches to the NS return address and transitions the core back to Non-Secure state. Before returning, the compiler-generated epilogue clears all registers that might leak Secure information.

**Interrupts:** each interrupt can be individually targeted to Secure or Non-Secure via the NVIC's Interrupt Target Non-Secure register (`NVIC_ITNS`), which is only writable from Secure state. Secure interrupts can preempt NS code; NS interrupts cannot preempt S code.

### Parameter Constraints

Because the NS stack is untrusted, all arguments and return values for gateway functions must pass via registers (R0–R3). This limits secure entry functions to at most four 32-bit parameters. Larger data must be passed by pointer, with the Secure side validating the pointer's security attribution using the `TT` (Test Target) instruction before dereferencing.

## Boot Sequence for a Dual-Image System

1. **RP2350 ROM boots in Secure state**, verifies the Secure image signature (if secure boot is enabled via OTP), and jumps to the Secure image's reset vector.
2. **Secure image runs `SystemInit`-equivalent code:**
   - Programs the SAU to define NS, S, and NSC regions (flash and SRAM boundaries for each image).
   - Configures ACCESSCTRL to assign peripherals (e.g., laser GPIO, watchdog) to Secure and others (e.g., servo PWM, UART) to Non-Secure.
   - Sets up the NSC veneer table — a block of `SG` + branch stubs, one per exported Secure function.
   - Configures Secure interrupt handlers (e.g., watchdog timeout, safety tilt fault).
   - Sets the NS vector table address (`SCB_NS->VTOR`), NS MSP (`MSP_NS`), and NS MSP limit.
3. **Secure image branches to the NS image's reset handler** using a function-pointer cast with the LSB cleared (indicating NS target), triggering the transition.
4. **NS image (Embassy firmware) boots normally**, unaware of TrustZone beyond having access to the veneer addresses for calling Secure functions.

## Rust Toolchain Status

### Compiler Support

Rust provides two unstable ABIs for TrustZone-M on `thumbv8m.main-none-eabi` targets, both requiring nightly:

- **`extern "C-cmse-nonsecure-entry"`** — marks a function as a Secure entry point. The compiler generates the `__acle_se_` symbol prefix, constrains parameters to registers only, and inserts register-clearing code before return. The linker uses these symbols to produce the veneer table. (Tracking issue: rust-lang/rust#75835, status: unstable with design concerns.)
- **`extern "C-cmse-nonsecure-call"`** — used on function pointers to call from S into NS (e.g., invoking an NS callback from a Secure interrupt handler). The compiler clears registers that might leak Secure data before the call. (Tracking issue: rust-lang/rust#81391.)

Both features have seen active work through 2024–2025 (improved error messages, ABI migration from attribute to `extern` syntax) but remain gated behind `#![feature(...)]`. The `arm-none-eabi-ld` linker (from the Arm GNU toolchain) is currently required for veneer generation, as `rust-lld` does not yet produce CMSE import libraries.

### Crate Ecosystem

- **`cortex-m` crate** — provides abstractions for SAU configuration and TT (Test Target) instructions.
- **`cortex-m-rt`** — handles vector table and reset handler setup; usable for both S and NS images.
- **Embassy (`embassy-rp`)** — supports RP2350 via `rp235xa`/`rp235xb` features and provides `imagedef-secure-exe` and `imagedef-nonsecure-exe` image definition options. However, Embassy has no first-class TrustZone partitioning support — it does not manage SAU setup, veneer generation, or Secure/Non-Secure image linking.
- **`trustzone-m-rs`** — a community example project demonstrating a complete Rust Secure + Non-Secure TrustZone-M application, based on Arm's reference guide. It targets QEMU but the patterns are directly transferable.

### Practical Build Implications

The Secure image and NS image are separate binaries compiled independently. The Secure image is linked first, producing an import library (`.o` veneer object) that the NS image links against to resolve gateway function addresses. This two-stage link is not automated by Cargo and requires a build script or Makefile orchestration. The Secure image targets `thumbv8m.main-none-eabi` with the `cmse` LLVM target feature; the NS image targets the same triple but without CMSE features.

## Applying to Catlaser Safety Architecture

### Secure World Responsibilities

The Secure image is small, synchronous, and does not need Embassy's async runtime. It consists of:

- **SAU/ACCESSCTRL initialization** — partitions memory and peripherals at boot.
- **Gateway functions** (NSC veneers, exactly two):
  - `set_laser_state(on: bool) -> GatewayStatus` — checks all safety invariants (watchdog active, beam currently moving per the dwell monitor) before toggling the laser GPIO. The GPIO itself is Secure; NS code physically cannot write it directly. The dwell monitor is fed by Secure-only reads of `PWM_CH1_CC` (pan + tilt compare), so NS cannot fabricate motion to unlock the laser.
  - `feed_watchdog()` — only resets the watchdog if the Secure side's own invariants are satisfied, and advances the dwell monitor by sampling the pan/tilt PWM compare registers on each call. This is the one recurring NS→S transition; everything the Secure world learns about the hardware flows through this call.
  - No other gateways exist. The Secure world accepts no safety observables from Non-Secure — NS may request laser state and watchdog refresh, never assert sensor data. A malicious or buggy NS image that claims the beam is moving while holding PWM compare constant simply has its lies ignored: the Secure world reads the registers itself.
- **Secure interrupt handlers:**
  - Watchdog timeout → forces laser off, enters safe state.
  - Power brownout (via POWMAN) → forces laser off.

### Non-Secure World Responsibilities

The NS image runs Embassy and handles everything that is not safety-critical:

- 200 Hz servo interpolation loop (PWM peripherals assigned to NS).
- UART parsing for commands from the Luckfox vision daemon (UART peripheral assigned to NS).
- Treat dispenser GPIO control.
- Calls into Secure gateway functions to request laser state changes, report sensor data, and feed the watchdog.

### Why This Matters

A buffer overflow in the UART parser, a logic bug in servo interpolation, or even deliberately malicious NS code cannot: write the laser GPIO, disable the watchdog, or spoof beam position to defeat the dwell cap — the Secure world reads the pan/tilt PWM compare registers directly, so NS-claimed motion is never consulted. Combined with a Class 2 (≤1 mW) laser source, this caps per-exposure retinal dose below the blink-reflex MPE regardless of mount orientation. These invariants are enforced by silicon, not by the correctness of the application firmware.

## Key References

- RP2350 Datasheet, Chapter 10: Security — Sections 10.2 (Processor security features), 10.6.2 (Bus access control) — `datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf`
- "Understanding RP2350's security features" White Paper (Nov 2025) — `pip.raspberrypi.com`
- Arm CMSIS-Core: Using TrustZone for ARMv8-M — `arm-software.github.io/CMSIS_6/main/Core/using_TrustZone_pg.html`
- Rust tracking issues: `rust-lang/rust#75835` (cmse-nonsecure-entry), `rust-lang/rust#81391` (cmse-nonsecure-call)
- `trustzone-m-rs` example project — `github.com/IoTS-P/trustzone-m-rs`
- Embassy `embassy-rp` docs — `docs.embassy.dev/embassy-rp/`
- "Highway to the TrustZone (Using Rust with TrustZone-M)" — `saschawise.com`
