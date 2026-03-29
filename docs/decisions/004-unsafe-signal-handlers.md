# ADR-004: Unsafe code for signal handler installation

## Status

Accepted

## Context

The workspace enforces `unsafe_code = "deny"` globally. The vision daemon requires graceful shutdown on SIGTERM (systemd stop) and SIGINT (developer Ctrl-C). Signal handler installation via `libc::signal` requires unsafe Rust because it is a C FFI call that modifies global process state.

The unsafe surface is minimal:

1. **`libc::signal(SIGTERM, handler)`** — registers the SIGTERM handler. Called once during startup.

2. **`libc::signal(SIGINT, handler)`** — registers the SIGINT handler. Called once during startup.

The handler function (`shutdown_handler`) performs a single `AtomicBool::store(true, Relaxed)` which is async-signal-safe: it compiles to a plain store instruction with no memory allocation, locking, or calls to non-reentrant functions.

## Decision

Allow `unsafe_code` in `main.rs` within the `catlaser-vision` crate via `#[expect(unsafe_code, reason = "...")]` on the `install_handler` function's unsafe block.

Within the module:
- The `unsafe` block contains exactly one operation (`libc::signal` call).
- A `// SAFETY:` comment documents the preconditions (signal-safe handler, valid function pointer, SIG_ERR check).
- The handler body is trivially signal-safe (single relaxed atomic store).
- The `SHUTDOWN` flag uses `Ordering::Relaxed` because it is monotonic (false → true, never reset) and a one-frame observation delay is acceptable.

## Consequences

- The vision daemon shuts down cleanly on SIGTERM/SIGINT, allowing Drop impls to stop camera streaming, ISP 3A, and close the serial port.
- The unsafe scope is confined to 2 call sites in one function in `main.rs`.
- All other modules in the vision crate remain under `deny(unsafe_code)`.
