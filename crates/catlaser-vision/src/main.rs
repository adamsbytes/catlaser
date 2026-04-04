//! Catlaser vision daemon.
//!
//! Camera capture, NPU inference, SORT tracking, servo targeting, and
//! IPC to the Python behavior engine over Unix domain socket.
//!
//! Entry point for the `catlaser-vision` binary. Initializes tracing,
//! installs signal handlers for graceful shutdown, constructs the
//! [`Pipeline`], and runs the frame processing loop
//! until SIGTERM or SIGINT is received.

mod camera;
mod detect;
mod embed;
mod encoder;
mod ipc;
mod npu;
mod pipeline;
mod proto;
mod safety;
mod serial;
mod streaming;
mod targeting;
mod tracker;

use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

use pipeline::{Pipeline, PipelineConfig, PipelineError};

// ---------------------------------------------------------------------------
// Signal handling
// ---------------------------------------------------------------------------

/// Global flag set by SIGTERM/SIGINT handlers to request graceful shutdown.
///
/// Checked at the top of each frame iteration. `Relaxed` ordering suffices
/// because the flag is monotonic (false → true, never reset) and the only
/// consequence of a one-frame delay in observing the write is processing
/// one extra frame before exiting.
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// Async-signal-safe handler that sets the shutdown flag.
///
/// The body is a single `AtomicBool::store` with `Relaxed` ordering,
/// which compiles to a plain store instruction — no allocation, no
/// locking, no non-reentrant function calls.
extern "C" fn shutdown_handler(_sig: libc::c_int) {
    SHUTDOWN.store(true, Ordering::Relaxed);
}

/// Installs SIGTERM and SIGINT handlers that set the [`SHUTDOWN`] flag.
///
/// Uses `libc::signal` to register an async-signal-safe handler. See ADR-004
/// for the safety argument.
fn install_signal_handlers() -> Result<(), PipelineError> {
    install_handler(libc::SIGTERM, "SIGTERM")?;
    install_handler(libc::SIGINT, "SIGINT")?;
    Ok(())
}

/// Registers [`shutdown_handler`] for the given signal.
fn install_handler(sig: libc::c_int, name: &'static str) -> Result<(), PipelineError> {
    #[expect(
        unsafe_code,
        clippy::as_conversions,
        clippy::fn_to_numeric_cast_any,
        reason = "libc::signal requires sighandler_t (usize) from function pointer — ADR-004"
    )]
    // SAFETY: shutdown_handler is async-signal-safe (single relaxed atomic
    // store). The handler is an extern "C" function at a static address.
    // libc::signal is a standard POSIX function. We check for SIG_ERR.
    let prev = unsafe { libc::signal(sig, shutdown_handler as libc::sighandler_t) };

    if prev == libc::SIG_ERR {
        return Err(PipelineError::Signal {
            signal: name,
            source: std::io::Error::last_os_error(),
        });
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

/// Runs the vision pipeline until shutdown is requested.
fn run() -> Result<(), PipelineError> {
    install_signal_handlers()?;

    let config = PipelineConfig::default();
    tracing::info!(
        model = %config.model_path.display(),
        serial = %config.serial_path.display(),
        "initializing vision pipeline"
    );

    let mut pipeline = Pipeline::init(config)?;
    tracing::info!("pipeline ready, entering main loop");

    while !SHUTDOWN.load(Ordering::Relaxed) {
        match pipeline.run_frame() {
            Ok(result) => {
                tracing::debug!(
                    seq = result.sequence,
                    detections = result.detection_count,
                    cats = result.cat_count,
                    tracks = result.track_count,
                    target = ?result.target_track_id,
                    pan = result.pan,
                    tilt = result.tilt,
                    laser = result.laser_on,
                    ceiling = result.safety.ceiling_y,
                    person = result.safety.person_in_frame,
                    ipc = result.ipc_connected,
                    brightness = format_args!("{:.2}", result.ambient_brightness),
                    "frame",
                );
            }
            Err(err) if err.is_transient() => {
                tracing::warn!(%err, "transient frame error, retrying");
            }
            Err(err) => {
                // A signal during the blocking capture poll can surface as
                // an EINTR-based camera error. If shutdown was requested,
                // treat this as a clean exit rather than a fatal error.
                if SHUTDOWN.load(Ordering::Relaxed) {
                    tracing::debug!(%err, "frame error during shutdown, exiting cleanly");
                    break;
                }
                return Err(err);
            }
        }
    }

    let frames = pipeline.frame_count();
    let drained = pipeline.frames_drained();
    tracing::info!(frames, drained, "shutdown requested, cleaning up");
    drop(pipeline);
    tracing::info!("shutdown complete");
    Ok(())
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_err| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    if let Err(err) = run() {
        tracing::error!(%err, "fatal error");
        return ExitCode::FAILURE;
    }

    ExitCode::SUCCESS
}
