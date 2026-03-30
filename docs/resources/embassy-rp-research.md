# Embassy RP2350 HAL (`embassy-rp`) — API Research

Reference crate version: **0.10.0** (`embassy-rp` on crates.io / `git` on docs.embassy.dev).
Docs: `https://docs.embassy.dev/embassy-rp/git/rp235xa/`
Source: `https://github.com/embassy-rs/embassy/tree/main/embassy-rp`

---

## Crate Overview

`embassy-rp` is the Embassy HAL targeting RP2040 and RP235x. It provides both **blocking and async** APIs for peripherals. When the `time-driver` feature is enabled, the TIMER peripheral is consumed as a 1 MHz global time source for `embassy-time`. The crate implements `embedded-hal` (v0.2 + v1.0), `embedded-hal-async`, `embedded-io`, and `embedded-io-async` traits, meaning drivers written against those traits are directly compatible.

Initialization is always `let p = embassy_rp::init(Default::default());` which returns a `Peripherals` struct owning every singleton. Interrupt binding uses the `bind_interrupts!` macro.

---

## UART — Async Receive

**Module:** `embassy_rp::uart`

There are two driver families: DMA-backed `Uart` (one-shot read/write with await) and interrupt-driven `BufferedUart` (ring-buffer backed, implements `embedded-io-async` traits).

### Key Types

| Type | Purpose |
|---|---|
| `Uart<'d, T, Async>` | DMA-driven UART. `read(&mut buf).await` blocks the task until the DMA transfer fills the buffer. Good for fixed-size packets. |
| `BufferedUart` / `BufferedUartRx` / `BufferedUartTx` | Interrupt-driven ring buffer. Implements `embedded_io_async::Read` / `BufRead`. Better for variable-length or streaming data. Splittable into independent RX/TX handles. |

### Config Struct

```rust
pub struct Config {
    pub baudrate: u32,        // default 115200
    pub data_bits: DataBits,  // Five, Six, Seven, Eight
    pub stop_bits: StopBits,  // One, Two
    pub parity: Parity,       // None, Even, Odd
    pub invert_tx: bool,
    pub invert_rx: bool,
    pub invert_rts: bool,
    pub invert_cts: bool,
}
```

Config is `#[non_exhaustive]` — construct via `Config::default()` and override fields.

### Construction (DMA mode — recommended for the 8-byte packed struct)

```rust
bind_interrupts!(struct Irqs {
    UART0_IRQ => uart::InterruptHandler<peripherals::UART0>;
});

let mut uart = Uart::new(
    p.UART0, p.PIN_0 /*TX*/, p.PIN_1 /*RX*/,
    Irqs, p.DMA_CH0, p.DMA_CH1,
    Config::default(),
);
let (mut tx, mut rx) = uart.split();
```

`rx.read(&mut buf).await` completes when the buffer is full (DMA transfer). For the 8-byte command struct this is ideal — one `.read_exact()` of 8 bytes per frame.

### Construction (Buffered mode — alternative)

```rust
let uart = BufferedUart::new(
    p.UART0, Irqs, p.PIN_0, p.PIN_1,
    &mut tx_buf, &mut rx_buf, Config::default(),
);
```

Runtime baud rate changes are supported: `uart.set_baudrate(new_baud)`.

### Relevance to project

For the 8-byte packed UART command struct at 200 Hz, DMA mode with `read_exact` on a fixed buffer is the cleanest approach. Avoid `BufferedUart` unless you need to handle variable-length or partial reads. The RP2350 has two UART instances (UART0, UART1); each can be mapped to several pin pairs. With TrustZone-M, the UART peripheral is assigned to the Non-Secure world via ACCESSCTRL.

---

## PWM — Servo Pulse Timing

**Module:** `embassy_rp::pwm`

The RP2350 has **12 PWM slices** (PWM_SLICE0–11), each with two channels (A and B) that share the same frequency/period but have independent duty cycles. Each GPIO pin is hard-mapped to a specific slice+channel.

### Config Struct

```rust
pub struct Config {
    pub invert_a: bool,
    pub invert_b: bool,
    pub phase_correct: bool,  // halves output frequency
    pub enable: bool,         // default: true
    pub divider: FixedU16<U4>, // 8.4 fixed-point fractional divider
    pub compare_a: u16,       // duty cycle threshold for channel A
    pub compare_b: u16,       // duty cycle threshold for channel B
    pub top: u16,             // counter wrap point (period = top + 1)
}
```

**Period formula (from docs):**  
`period_clocks = (top + 1) × (phase_correct ? 2 : 1) × divider`

### Calculating 50 Hz Servo PWM

System clock: 150 MHz (RP2350 default). Target period: 20 ms (50 Hz).

Target total clocks = 150,000,000 / 50 = 3,000,000.

With `top = 29_999` (so period counts = 30,000) → divider = 3,000,000 / 30,000 = **100**.

This gives 0.667 µs per counter tick. Servo pulse mapping:

| Servo pulse | Counter ticks | `compare_x` value |
|---|---|---|
| 500 µs (min) | 750 | 750 |
| 1500 µs (center) | 2250 | 2250 |
| 2500 µs (max) | 3750 | 3750 |

```rust
use embassy_rp::pwm::{Pwm, Config};
use fixed::traits::ToFixed;

let mut config = Config::default();
config.top = 29_999;
config.divider = 100u8.to_fixed();  // integer divider = 100
config.compare_a = 2250;            // center position

let mut pwm_pan = Pwm::new_output_a(p.PWM_SLICE0, p.PIN_0, config.clone());
```

Update position at runtime:

```rust
config.compare_a = new_pulse_ticks;
pwm_pan.set_config(&config);
```

### Two servos (pan + tilt)

Use both channels of one slice (if pins allow), or two separate slices. `Pwm::new_output_ab(slice, pin_a, pin_b, config)` drives both channels with independent duty cycles on a shared period.

### Note on the `fixed` crate

The `divider` field is `FixedU16<U4>` from the `fixed` crate — 8 integer bits, 4 fractional bits. Maximum integer divider is 255. Use `ToFixed` trait for conversion. The `fixed` crate is a required dependency.

---

## ADC — VBUS Monitoring

**Module:** `embassy_rp::adc`

The RP2350 has a 12-bit SAR ADC with 5 input channels: GPIO26–29 (ADC0–3) and an internal temperature sensor (channel 4). It runs from a 48 MHz clock.

### Driver Modes

- **Blocking:** `Adc::new_blocking(p.ADC, Config::default())`
- **Async:** `Adc::new(p.ADC, Irqs, Config::default())` — uses interrupt to signal completion.

### Single-shot read

```rust
bind_interrupts!(struct Irqs {
    ADC_IRQ_FIFO => adc::InterruptHandler;
});

let mut adc = Adc::new(p.ADC, Irqs, adc::Config::default());
let mut vbus_pin = adc::Channel::new_pin(p.PIN_29, Pull::None);
let raw: u16 = adc.read(&mut vbus_pin).await.unwrap();
let voltage = (raw as f32) * 3.3 / 4095.0;
```

### Multi-sample DMA mode

For continuous monitoring: `adc.read_many(channel, &mut buf, div).await`. The `div` parameter sets the sample rate: `div = floor(48_000_000 / sample_rate - 1)`. Values below 96 are clamped.

### VBUS monitoring approach

On the Pico 2, VBUS is available through a voltage divider on GPIO29/ADC3. Reading this pin gives the USB 5 V rail voltage (scaled to 0–3.3 V). For monitoring the Luckfox power connection, a simple resistor divider on one of ADC0–2 would work, with periodic async reads in a low-priority task. With TrustZone-M, the ADC peripheral can be assigned to the Non-Secure world (power monitoring reports to Secure via gateway), or to the Secure world (Secure brownout handler reads directly).

---

## GPIO — Laser & IR Break-Beam

**Module:** `embassy_rp::gpio`

### Output (Laser control)

```rust
use embassy_rp::gpio::{Output, Level};

let mut laser = Output::new(p.PIN_15, Level::Low);
laser.set_high();  // laser on
laser.set_low();   // laser off
```

`Output` provides: `set_high()`, `set_low()`, `set_level(Level)`, `toggle()`, `is_set_high()`.

### Input (IR break-beam sensor)

```rust
use embassy_rp::gpio::{Input, Pull};

let beam = Input::new(p.PIN_16, Pull::Up);
```

**Blocking poll:** `beam.is_high()`, `beam.is_low()`.

**Async edge detection:** `beam.wait_for_low().await`, `beam.wait_for_high().await`, `beam.wait_for_rising_edge().await`, `beam.wait_for_falling_edge().await`, `beam.wait_for_any_edge().await`. These use interrupt-backed wakers — the core sleeps until the edge occurs, no polling.

### Relevance to project

- **Laser GPIO**: With TrustZone-M, the laser pin is assigned to the Secure world via ACCESSCTRL. Non-Secure code cannot write it directly — only the Secure `set_laser_state` gateway can actuate the laser after validating safety invariants.
- **IR break-beam**: Use `Input` with `Pull::Up` and async edge detection to monitor beam interruption without busy-waiting. Schmitt trigger is configurable: `beam.set_schmitt(true)`. Hopper sensor GPIO can remain Non-Secure (informational, not safety-critical).

---

## Watchdog Timer

**Module:** `embassy_rp::watchdog`

The RP2350 watchdog is a countdown timer that resets the chip if it reaches zero. It resets everything except ROSC and XOSC. With TrustZone-M, the watchdog peripheral is assigned to the Secure world via ACCESSCTRL — Non-Secure code feeds it through a Secure gateway function.

### API

```rust
use embassy_rp::watchdog::Watchdog;
use embassy_time::Duration;

let mut watchdog = Watchdog::new(p.WATCHDOG);

// RP2040 only: watchdog.enable_tick_generation(12);
// Not needed on RP2350 — tick generator runs automatically.

// Optional: don't pause watchdog during debug
watchdog.pause_on_debug(false);

// Start with a 500ms timeout
watchdog.start(Duration::from_millis(500));

// In your main loop — feed (reload) the timer
watchdog.feed(Duration::from_millis(500));
```

### Key methods

| Method | Description |
|---|---|
| `new(peripheral)` | Construct. Takes ownership of the WATCHDOG peripheral singleton. |
| `enable_tick_generation(cycles: u8)` | **RP2040 only.** Not needed on RP2350 — tick generator runs automatically. |
| `pause_on_debug(bool)` | Pause timer when CPU is halted by debugger/JTAG. |
| `start(Duration)` | Configure reset triggers, load counter, enable. |
| `feed(Duration)` | Reload the counter. Duration can differ from start — this is the new timeout. |
| `stop()` | Disable the watchdog. |
| `trigger_reset()` | Force an immediate system reset. |
| `set_scratch(index, u32)` / `get_scratch(index)` | 8 scratch registers (0–7) that survive watchdog resets. Useful for passing state across resets. |
| `reset_reason()` | Returns `Option<ResetReason>` — `Forced` or `TimedOut`. |

### Relevance to project

The 500 ms watchdog fits comfortably within the hardware maximum. With TrustZone-M, the watchdog peripheral is owned by the Secure world. The Non-Secure Embassy firmware feeds it through a gateway function (`feed_watchdog`), which the Secure side only honors if its own invariants are satisfied. If the Luckfox stops sending (crash, hang, cable disconnect), the watchdog fires after 500 ms — the Secure interrupt handler forces the laser off and homes servos.

The scratch registers can persist a "last known state" or error code across watchdog resets without needing flash writes.

Note: the RP2040 had an E1 errata where the watchdog counter decremented by 2 instead of 1 (HAL compensated automatically). This does not affect the RP2350.

---

## Interrupt Binding Pattern

All async peripherals on embassy-rp require interrupt handlers bound via the `bind_interrupts!` macro:

```rust
use embassy_rp::bind_interrupts;
use embassy_rp::peripherals::{UART0, ADC};

bind_interrupts!(struct Irqs {
    UART0_IRQ => embassy_rp::uart::InterruptHandler<UART0>;
    ADC_IRQ_FIFO => embassy_rp::adc::InterruptHandler;
});
```

This is a compile-time checked, type-safe registration — no runtime overhead.

---

## Cargo Feature Flags (relevant subset)

| Feature | Purpose |
|---|---|
| `rp235xa` / `rp235xb` | Target the RP2350 silicon (select based on variant). Replaces `rp2040`. |
| `time-driver` | Use TIMER as embassy-time driver (1 MHz tick). Required for `Timer::after`, `Ticker`, etc. |
| `critical-section-impl` | Safe critical sections for multicore. Not needed if using only core 0. |
| `unstable-pac` | Re-export `rp-pac` as `embassy_rp::pac` for register-level access when needed. |
| `defmt` | Enable defmt formatting for debug logging. |

---

## Recommended Crate Ecosystem

| Crate | Version | Role |
|---|---|---|
| `embassy-executor` | 0.10.x | Async task executor |
| `embassy-time` | 0.5.x | Timekeeping (`Ticker::every` for 200 Hz loop) |
| `embassy-sync` | 0.8.x | Channels, mutexes, signals between tasks |
| `embassy-rp` | 0.10.x | RP2350 HAL |
| `fixed` | 1.28+ | Required for PWM divider type |
| `defmt` + `defmt-rtt` | 1.x | Lightweight debug logging over SWD |
| `panic-probe` | — | Breakpoint on panic for debug |
| `cortex-m-rt` | 0.7.x | Runtime / vector table |
