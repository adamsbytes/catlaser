//! NPU inference error types.

use std::path::PathBuf;

/// Errors from RKNN NPU model loading, inference, and memory management.
#[derive(Debug, thiserror::Error)]
pub enum NpuError {
    /// The RKNN runtime library could not be loaded.
    #[error("failed to load RKNN library from {path}: {source}")]
    LibraryLoad {
        /// Library path attempted.
        path: PathBuf,
        /// Loading error.
        source: libloading::Error,
    },

    /// A required symbol was not found in the RKNN library.
    #[error("RKNN symbol {symbol} not found: {source}")]
    Symbol {
        /// Symbol name.
        symbol: &'static str,
        /// Loading error.
        source: libloading::Error,
    },

    /// `rknn_init` failed to load the model.
    #[error("rknn_init failed with code {code}")]
    Init {
        /// RKNN error code.
        code: i32,
    },

    /// `rknn_query` failed.
    #[error("rknn_query({command}) failed with code {code}")]
    Query {
        /// Query command name.
        command: &'static str,
        /// RKNN error code.
        code: i32,
    },

    /// `rknn_create_mem` returned null (DMA memory exhaustion).
    #[error("rknn_create_mem failed for {purpose} (requested {size} bytes)")]
    MemAlloc {
        /// What the memory was for (e.g. "input 0", "output 2").
        purpose: String,
        /// Requested allocation size.
        size: u32,
    },

    /// `rknn_set_io_mem` failed to bind a tensor to its memory.
    #[error("rknn_set_io_mem failed for {purpose} with code {code}")]
    MemBind {
        /// What the memory was for.
        purpose: String,
        /// RKNN error code.
        code: i32,
    },

    /// `rknn_run` failed.
    #[error("rknn_run failed with code {code}")]
    Run {
        /// RKNN error code.
        code: i32,
    },

    /// `rknn_mem_sync` failed.
    #[error("rknn_mem_sync failed for output {index} with code {code}")]
    MemSync {
        /// Output tensor index.
        index: u32,
        /// RKNN error code.
        code: i32,
    },

    /// Input data size does not match the expected tensor size.
    #[error("input size mismatch: expected {expected} bytes, got {actual}")]
    InputSizeMismatch {
        /// Expected byte count from tensor attr.
        expected: u32,
        /// Actual byte count provided.
        actual: u32,
    },

    /// Output tensor index is out of range.
    #[error("output index {index} out of range (model has {count} outputs)")]
    OutputIndexOutOfRange {
        /// The invalid index.
        index: u32,
        /// Number of output tensors.
        count: u32,
    },

    /// The model reported zero inputs or zero outputs.
    #[error("model has {n_input} inputs and {n_output} outputs, expected at least 1 of each")]
    InvalidModelTopology {
        /// Number of inputs reported.
        n_input: u32,
        /// Number of outputs reported.
        n_output: u32,
    },
}
