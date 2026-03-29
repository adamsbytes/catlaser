# ADR-003: Unsafe FFI in serial module

## Status

Accepted

## Context

The workspace enforces `unsafe_code = "deny"` globally. The vision daemon's serial module transmits 8-byte `ServoCommand` frames to the MCU over UART at 115200 baud. This requires POSIX termios configuration and raw fd writes, both of which are C library calls with no safe Rust wrapper in the dependency set.

The unsafe surface is small and well-bounded:

1. **termios configuration** (`tcgetattr`, `cfsetispeed`, `cfsetospeed`, `tcsetattr`) — reads and writes a `libc::termios` struct to set raw 8-N-1 mode at 115200 baud. Called once during `SerialPort::open()`.

2. **`libc::write`** — writes 8 bytes to the UART file descriptor. Called once per servo command (~15 Hz).

## Decision

Allow `unsafe_code` in `serial.rs` within the `catlaser-vision` crate via `#[expect(unsafe_code, reason = "...")]` on each unsafe block.

Within the module:
- Every `unsafe` block has a `// SAFETY:` comment documenting the preconditions.
- Each block contains exactly one unsafe operation (`multiple_unsafe_ops_per_block = "deny"`).
- Safe wrapper functions validate inputs and translate OS errors into typed `SerialError` variants before entering unsafe code.
- The file descriptor is owned via `OwnedFd`, guaranteeing valid lifetime and automatic close.

## Consequences

- Unsafe surface area is confined to 6 call sites in one file (4 termios calls, 1 open indirectly via std, 1 write).
- The command packing logic (`build_command`) is entirely safe and independently testable.
- All other modules in the vision crate remain under `deny(unsafe_code)`.
