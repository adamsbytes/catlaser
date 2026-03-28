//! Rockchip rkaiq ISP 3A library FFI.
//!
//! Provides safe Rust wrappers around the rkaiq `uapi2` C API for
//! auto-exposure, auto-white-balance, and auto-gain on the RV1106.
//! The library is loaded at runtime via `libloading` so the crate
//! compiles and tests pass on machines without `librkaiq.so`.
//!
//! All unsafe code in this module is covered by ADR-001.

use std::ffi::{CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};

use super::error::CameraError;

// ---------------------------------------------------------------------------
// rkaiq constants
// ---------------------------------------------------------------------------

/// `RK_AIQ_WORKING_MODE_NORMAL` — single-exposure SDR mode.
const RK_AIQ_WORKING_MODE_NORMAL: c_int = 0;

/// Default IQ tuning file directory on Luckfox Buildroot.
const DEFAULT_IQ_DIR: &str = "/etc/iqfiles/";

/// Default library search path on the target.
const DEFAULT_LIB_PATH: &str = "/usr/lib/librkaiq.so";

// ---------------------------------------------------------------------------
// Function pointer types matching rkaiq uapi2 signatures
// ---------------------------------------------------------------------------

/// `rk_aiq_uapi2_sysctl_init(sensor_entity, iq_dir, err_cb, metas_cb) → *mut ctx`
type FnSysctlInit = unsafe extern "C" fn(
    sensor_entity: *const c_char,
    iq_file_dir: *const c_char,
    err_cb: *const c_void,
    metas_cb: *const c_void,
) -> *mut c_void;

/// `rk_aiq_uapi2_sysctl_prepare(ctx, width, height, mode) → c_int`
type FnSysctlPrepare =
    unsafe extern "C" fn(ctx: *mut c_void, width: u32, height: u32, mode: c_int) -> c_int;

/// `rk_aiq_uapi2_sysctl_start(ctx) → c_int`
type FnSysctlStart = unsafe extern "C" fn(ctx: *mut c_void) -> c_int;

/// `rk_aiq_uapi2_sysctl_stop(ctx, keep_ext_hw_st) → c_int`
type FnSysctlStop = unsafe extern "C" fn(ctx: *mut c_void, keep_ext_hw_st: c_int) -> c_int;

/// `rk_aiq_uapi2_sysctl_deinit(ctx) → void`
type FnSysctlDeinit = unsafe extern "C" fn(ctx: *mut c_void);

/// `rk_aiq_uapi2_sysctl_enumStaticMetas(index, metas) → c_int`
type FnSysctlEnumStaticMetas =
    unsafe extern "C" fn(index: c_int, metas: *mut RkAiqStaticMetas) -> c_int;

// ---------------------------------------------------------------------------
// rkaiq data structures
// ---------------------------------------------------------------------------

/// Simplified `rk_aiq_static_info_t` — we only need the sensor entity name.
#[repr(C)]
struct RkAiqStaticMetas {
    /// Sensor entity name (null-terminated).
    sensor_info_entity_name: [c_char; 64],
    _padding: [u8; 1024],
}

impl RkAiqStaticMetas {
    const fn zeroed() -> Self {
        Self {
            sensor_info_entity_name: [0; 64],
            _padding: [0; 1024],
        }
    }

    /// Extracts the sensor entity name as a Rust string.
    ///
    /// Returns an empty string if the name is not valid UTF-8 or empty.
    fn entity_name(&self) -> String {
        let bytes: Vec<u8> = self
            .sensor_info_entity_name
            .iter()
            .take_while(|&&b| b != 0)
            .map(|&b| b.cast_unsigned())
            .collect();
        String::from_utf8(bytes).unwrap_or_default()
    }
}

// ---------------------------------------------------------------------------
// Loaded library handle
// ---------------------------------------------------------------------------

/// Holds the dynamically loaded rkaiq function pointers.
struct RkaiqLibrary {
    _lib: libloading::Library,
    sysctl_init: FnSysctlInit,
    sysctl_prepare: FnSysctlPrepare,
    sysctl_start: FnSysctlStart,
    sysctl_stop: FnSysctlStop,
    sysctl_deinit: FnSysctlDeinit,
    sysctl_enum_static_metas: FnSysctlEnumStaticMetas,
}

impl std::fmt::Debug for RkaiqLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RkaiqLibrary").finish_non_exhaustive()
    }
}

/// Loads a single typed symbol from a `libloading::Library`.
///
/// Returns the raw function pointer, which remains valid as long as
/// the `Library` handle is alive.
macro_rules! load_symbol {
    ($lib:expr, $fn_type:ty, $name:literal) => {{
        #[expect(
            unsafe_code,
            clippy::undocumented_unsafe_blocks,
            reason = "libloading symbol lookup — ADR-001. SAFETY: symbol name matches \
                      the rkaiq uapi2 header; function pointer is valid for Library lifetime."
        )]
        let sym: libloading::Symbol<'_, $fn_type> = unsafe {
            $lib.get(concat!($name, "\0").as_bytes())
        }
        .map_err(|source| CameraError::RkaiqSymbol {
            symbol: $name,
            source,
        })?;
        *sym
    }};
}

impl RkaiqLibrary {
    /// Loads `librkaiq.so` from the given path and resolves all required symbols.
    fn load(lib_path: &Path) -> Result<Self, CameraError> {
        #[expect(
            unsafe_code,
            reason = "libloading::Library::new loads a shared object — ADR-001"
        )]
        // SAFETY: we are loading a known Rockchip system library. The path
        // is validated by the caller (defaults to /usr/lib/librkaiq.so on
        // the target device).
        let lib = unsafe { libloading::Library::new(lib_path) }.map_err(|source| {
            CameraError::RkaiqLibraryLoad {
                path: lib_path.to_path_buf(),
                source,
            }
        })?;

        let sysctl_init = load_symbol!(lib, FnSysctlInit, "rk_aiq_uapi2_sysctl_init");
        let sysctl_prepare = load_symbol!(lib, FnSysctlPrepare, "rk_aiq_uapi2_sysctl_prepare");
        let sysctl_start = load_symbol!(lib, FnSysctlStart, "rk_aiq_uapi2_sysctl_start");
        let sysctl_stop = load_symbol!(lib, FnSysctlStop, "rk_aiq_uapi2_sysctl_stop");
        let sysctl_deinit = load_symbol!(lib, FnSysctlDeinit, "rk_aiq_uapi2_sysctl_deinit");
        let sysctl_enum_static_metas = load_symbol!(
            lib,
            FnSysctlEnumStaticMetas,
            "rk_aiq_uapi2_sysctl_enumStaticMetas"
        );

        Ok(Self {
            _lib: lib,
            sysctl_init,
            sysctl_prepare,
            sysctl_start,
            sysctl_stop,
            sysctl_deinit,
            sysctl_enum_static_metas,
        })
    }
}

// ---------------------------------------------------------------------------
// ISP controller (safe public API)
// ---------------------------------------------------------------------------

/// Configuration for the ISP 3A controller.
#[derive(Debug, Clone)]
pub(crate) struct IspConfig {
    /// Path to `librkaiq.so`.
    pub lib_path: PathBuf,
    /// Path to the IQ tuning file directory.
    pub iq_dir: PathBuf,
    /// Capture width (must match V4L2 format).
    pub width: u32,
    /// Capture height (must match V4L2 format).
    pub height: u32,
}

impl Default for IspConfig {
    fn default() -> Self {
        Self {
            lib_path: PathBuf::from(DEFAULT_LIB_PATH),
            iq_dir: PathBuf::from(DEFAULT_IQ_DIR),
            width: 640,
            height: 480,
        }
    }
}

/// Safe wrapper around the rkaiq ISP 3A library lifecycle.
///
/// Initializes the ISP 3A algorithms (auto-exposure, auto-white-balance,
/// auto-gain) at construction. The algorithms run on a separate internal
/// thread managed by the library, feeding ISP parameters via the
/// `rkisp-input-params` V4L2 metadata node.
///
/// Must be started before V4L2 capture begins, and stopped before capture
/// ends. Drop handles cleanup automatically.
pub(crate) struct IspController {
    lib: RkaiqLibrary,
    ctx: *mut c_void,
    started: bool,
}

impl std::fmt::Debug for IspController {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IspController")
            .field("ctx", &self.ctx)
            .field("started", &self.started)
            .finish_non_exhaustive()
    }
}

impl IspController {
    /// Discovers the sensor entity name, initializes rkaiq, and prepares
    /// the ISP pipeline for the given resolution.
    #[tracing::instrument(skip_all, fields(width = config.width, height = config.height))]
    pub(crate) fn init(config: &IspConfig) -> Result<Self, CameraError> {
        let lib = RkaiqLibrary::load(&config.lib_path)?;

        // Discover the sensor entity name from the first camera.
        let sensor_name = Self::discover_sensor(&lib)?;
        tracing::info!(sensor = %sensor_name, "discovered ISP sensor");

        let c_sensor = CString::new(sensor_name).map_err(|_err| CameraError::RkaiqCall {
            function: "CString::new(sensor_name)",
            code: -1_i32,
        })?;

        let c_iq_dir = CString::new(
            config
                .iq_dir
                .to_str()
                .ok_or(CameraError::RkaiqCall {
                    function: "iq_dir to_str",
                    code: -1_i32,
                })?
                .as_bytes()
                .to_vec(),
        )
        .map_err(|_err| CameraError::RkaiqCall {
            function: "CString::new(iq_dir)",
            code: -1_i32,
        })?;

        // Initialize rkaiq.
        #[expect(unsafe_code, reason = "rkaiq FFI call: sysctl_init — ADR-001")]
        // SAFETY: c_sensor and c_iq_dir are valid null-terminated strings.
        // NULL callbacks are accepted by rkaiq (uses internal defaults).
        let ctx = unsafe {
            (lib.sysctl_init)(
                c_sensor.as_ptr(),
                c_iq_dir.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };

        if ctx.is_null() {
            return Err(CameraError::RkaiqCall {
                function: "rk_aiq_uapi2_sysctl_init",
                code: -1_i32,
            });
        }

        // Prepare the ISP pipeline for the target resolution.
        #[expect(unsafe_code, reason = "rkaiq FFI call: sysctl_prepare — ADR-001")]
        // SAFETY: ctx is a valid, non-null rkaiq context from a successful init.
        let ret = unsafe {
            (lib.sysctl_prepare)(ctx, config.width, config.height, RK_AIQ_WORKING_MODE_NORMAL)
        };

        if ret != 0_i32 {
            // Clean up on failure.
            #[expect(
                unsafe_code,
                clippy::semicolon_outside_block,
                reason = "rkaiq FFI call: sysctl_deinit on error path — ADR-001"
            )]
            // SAFETY: ctx is valid; deinit releases all resources.
            unsafe {
                (lib.sysctl_deinit)(ctx);
            }
            return Err(CameraError::RkaiqCall {
                function: "rk_aiq_uapi2_sysctl_prepare",
                code: ret,
            });
        }

        Ok(Self {
            lib,
            ctx,
            started: false,
        })
    }

    /// Starts the ISP 3A algorithm loop. Call before starting V4L2 capture.
    pub(crate) fn start(&mut self) -> Result<(), CameraError> {
        #[expect(unsafe_code, reason = "rkaiq FFI call: sysctl_start — ADR-001")]
        // SAFETY: self.ctx is a valid, prepared rkaiq context.
        let ret = unsafe { (self.lib.sysctl_start)(self.ctx) };

        if ret != 0_i32 {
            return Err(CameraError::RkaiqCall {
                function: "rk_aiq_uapi2_sysctl_start",
                code: ret,
            });
        }

        self.started = true;
        tracing::info!("ISP 3A started");
        Ok(())
    }

    /// Stops the ISP 3A algorithm loop. Call before stopping V4L2 capture.
    pub(crate) fn stop(&mut self) -> Result<(), CameraError> {
        if !self.started {
            return Ok(());
        }

        #[expect(unsafe_code, reason = "rkaiq FFI call: sysctl_stop — ADR-001")]
        // SAFETY: self.ctx is a valid, started rkaiq context.
        // keep_ext_hw_st = 0 means don't preserve external hardware state.
        let ret = unsafe { (self.lib.sysctl_stop)(self.ctx, 0_i32) };

        if ret != 0_i32 {
            return Err(CameraError::RkaiqCall {
                function: "rk_aiq_uapi2_sysctl_stop",
                code: ret,
            });
        }

        self.started = false;
        tracing::info!("ISP 3A stopped");
        Ok(())
    }

    /// Discovers the sensor entity name using `enumStaticMetas` for camera
    /// index 0 (the SC3336).
    fn discover_sensor(lib: &RkaiqLibrary) -> Result<String, CameraError> {
        let mut metas = RkAiqStaticMetas::zeroed();

        #[expect(
            unsafe_code,
            reason = "rkaiq FFI call: sysctl_enumStaticMetas — ADR-001"
        )]
        // SAFETY: metas is a zeroed struct with sufficient size. Index 0
        // queries the first (and only) camera on the SC3336 module.
        let ret = unsafe { (lib.sysctl_enum_static_metas)(0_i32, &raw mut metas) };

        if ret != 0_i32 {
            return Err(CameraError::RkaiqCall {
                function: "rk_aiq_uapi2_sysctl_enumStaticMetas",
                code: ret,
            });
        }

        let name = metas.entity_name();
        if name.is_empty() {
            return Err(CameraError::RkaiqCall {
                function: "enumStaticMetas returned empty sensor name",
                code: 0,
            });
        }

        Ok(name)
    }
}

impl Drop for IspController {
    fn drop(&mut self) {
        // Stop if still running.
        if self.started {
            #[expect(unsafe_code, reason = "rkaiq FFI call: sysctl_stop in drop — ADR-001")]
            // SAFETY: self.ctx is valid; stop is idempotent in the library.
            unsafe {
                (self.lib.sysctl_stop)(self.ctx, 0_i32);
            }
        }

        #[expect(
            unsafe_code,
            clippy::semicolon_outside_block,
            reason = "rkaiq FFI call: sysctl_deinit in drop — ADR-001"
        )]
        // SAFETY: self.ctx is a valid rkaiq context. After deinit, the
        // context pointer must not be used again (but we're in drop, so
        // it won't be).
        unsafe {
            (self.lib.sysctl_deinit)(self.ctx);
        }

        tracing::debug!("ISP controller destroyed");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_isp_config() {
        let config = IspConfig::default();
        assert_eq!(
            config.lib_path,
            PathBuf::from("/usr/lib/librkaiq.so"),
            "default library path must be /usr/lib/librkaiq.so"
        );
        assert_eq!(
            config.iq_dir,
            PathBuf::from("/etc/iqfiles/"),
            "default IQ directory must be /etc/iqfiles/"
        );
        assert_eq!(config.width, 640, "default width must be 640");
        assert_eq!(config.height, 480, "default height must be 480");
    }

    #[test]
    fn test_load_missing_library() {
        let result = RkaiqLibrary::load(Path::new("/nonexistent/librkaiq.so"));
        let Err(err) = result else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("loading from nonexistent path must fail");
            }
        };
        assert!(
            matches!(err, CameraError::RkaiqLibraryLoad { .. }),
            "error must be RkaiqLibraryLoad, got: {err}"
        );
    }

    #[test]
    fn test_init_with_missing_library() {
        let config = IspConfig {
            lib_path: PathBuf::from("/nonexistent/librkaiq.so"),
            ..IspConfig::default()
        };
        let result = IspController::init(&config);
        assert!(result.is_err(), "init must fail when library is absent");
    }

    #[test]
    fn test_static_metas_entity_name_empty() {
        let metas = RkAiqStaticMetas::zeroed();
        assert!(
            metas.entity_name().is_empty(),
            "zeroed metas must produce empty entity name"
        );
    }

    #[test]
    fn test_static_metas_entity_name_extraction() {
        let mut metas = RkAiqStaticMetas::zeroed();
        let name = b"m00_b_sc3336 4-0030";
        #[expect(
            clippy::indexing_slicing,
            reason = "test data is shorter than the 64-byte array"
        )]
        for (i, &byte) in name.iter().enumerate() {
            metas.sensor_info_entity_name[i] = byte.cast_signed();
        }
        assert_eq!(
            metas.entity_name(),
            "m00_b_sc3336 4-0030",
            "entity name extraction must match input"
        );
    }
}
