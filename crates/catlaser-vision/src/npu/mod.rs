//! RKNN NPU inference on the RV1106.
//!
//! Provides [`Model`] for loading `.rknn` models and running zero-copy
//! inference on the integrated NPU. The library (`librknnmrt.so`) is loaded
//! at runtime via `libloading`, so the crate compiles and tests pass on
//! x86 development machines without the target library present.
//!
//! The module also provides pure-Rust utilities for working with NPU output
//! tensors: NC1HWC2-to-NCHW layout conversion and INT8 affine dequantization
//! (see [`tensor`]).

pub(crate) mod error;
mod rknn;
pub(crate) mod tensor;

use std::path::PathBuf;

pub(crate) use rknn::Model;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Default path to the RKNN runtime library on the RV1106 target.
///
/// The actual shared object is `librknnmrt.so` (not `librknn_api.so` —
/// that's the header name, this is the library name on RV1103/RV1106).
const DEFAULT_LIB_PATH: &str = "/usr/lib/librknnmrt.so";

/// NPU configuration.
#[derive(Debug, Clone)]
pub(crate) struct NpuConfig {
    /// Path to `librknnmrt.so`.
    pub lib_path: PathBuf,
}

impl Default for NpuConfig {
    fn default() -> Self {
        Self {
            lib_path: PathBuf::from(DEFAULT_LIB_PATH),
        }
    }
}

// ---------------------------------------------------------------------------
// Model priority
// ---------------------------------------------------------------------------

/// NPU scheduling priority for a model context.
///
/// When multiple models share the single-core RV1106 NPU, priority controls
/// time-slice scheduling. Use [`High`](Self::High) for the latency-critical
/// detection model (YOLO) and [`Low`](Self::Low) for the infrequent re-ID
/// model (`MobileNetV2`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ModelPriority {
    /// `RKNN_FLAG_PRIOR_HIGH` — highest NPU scheduling priority.
    High,
    /// `RKNN_FLAG_PRIOR_MEDIUM` — default scheduling priority.
    Medium,
    /// `RKNN_FLAG_PRIOR_LOW` — lowest scheduling priority.
    Low,
}

impl ModelPriority {
    /// Returns the RKNN priority flag value for `rknn_init`.
    pub(super) const fn flag(self) -> u32 {
        // Values from rknn_api.h: RKNN_FLAG_PRIOR_HIGH/MEDIUM/LOW.
        match self {
            Self::High => 0x00,
            Self::Medium => 0x01,
            Self::Low => 0x02,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- NpuConfig ---

    #[test]
    fn test_default_config() {
        let config = NpuConfig::default();
        assert_eq!(
            config.lib_path,
            PathBuf::from("/usr/lib/librknnmrt.so"),
            "default library path"
        );
    }

    // --- ModelPriority ---

    #[test]
    fn test_priority_flags() {
        assert_eq!(ModelPriority::High.flag(), 0x00, "high priority flag");
        assert_eq!(ModelPriority::Medium.flag(), 0x01, "medium priority flag");
        assert_eq!(ModelPriority::Low.flag(), 0x02, "low priority flag");
    }

    // --- Error display snapshots ---

    #[test]
    fn test_error_display_library_load() {
        let err = error::NpuError::LibraryLoad {
            path: PathBuf::from("/usr/lib/librknnmrt.so"),
            source: libloading::Error::DlOpenUnknown,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"failed to load RKNN library from /usr/lib/librknnmrt.so: dlopen failed, but system did not report the error"
        );
    }

    #[test]
    fn test_error_display_init() {
        let err = error::NpuError::Init { code: -1_i32 };
        insta::assert_snapshot!(err.to_string(), @"rknn_init failed with code -1");
    }

    #[test]
    fn test_error_display_query() {
        let err = error::NpuError::Query {
            command: "NATIVE_OUTPUT_ATTR",
            code: -2_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"rknn_query(NATIVE_OUTPUT_ATTR) failed with code -2"
        );
    }

    #[test]
    fn test_error_display_mem_alloc() {
        let err = error::NpuError::MemAlloc {
            purpose: String::from("output 2"),
            size: 921_600,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"rknn_create_mem failed for output 2 (requested 921600 bytes)"
        );
    }

    #[test]
    fn test_error_display_mem_bind() {
        let err = error::NpuError::MemBind {
            purpose: String::from("input 0"),
            code: -4_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"rknn_set_io_mem failed for input 0 with code -4"
        );
    }

    #[test]
    fn test_error_display_run() {
        let err = error::NpuError::Run { code: -1_i32 };
        insta::assert_snapshot!(err.to_string(), @"rknn_run failed with code -1");
    }

    #[test]
    fn test_error_display_mem_sync() {
        let err = error::NpuError::MemSync {
            index: 3,
            code: -1_i32,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"rknn_mem_sync failed for output 3 with code -1"
        );
    }

    #[test]
    fn test_error_display_input_size_mismatch() {
        let err = error::NpuError::InputSizeMismatch {
            expected: 921_600,
            actual: 460_800,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"input size mismatch: expected 921600 bytes, got 460800"
        );
    }

    #[test]
    fn test_error_display_output_index_out_of_range() {
        let err = error::NpuError::OutputIndexOutOfRange {
            index: 10,
            count: 9,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"output index 10 out of range (model has 9 outputs)"
        );
    }

    #[test]
    fn test_error_display_invalid_topology() {
        let err = error::NpuError::InvalidModelTopology {
            n_input: 0,
            n_output: 9,
        };
        insta::assert_snapshot!(
            err.to_string(),
            @"model has 0 inputs and 9 outputs, expected at least 1 of each"
        );
    }
}
