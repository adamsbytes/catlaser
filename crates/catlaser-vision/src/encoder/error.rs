//! Hardware encoder error types.

use std::path::PathBuf;

/// Errors from RKMPI VENC hardware encoder initialization and operation.
#[derive(Debug, thiserror::Error)]
pub enum EncoderError {
    /// The RKMPI library could not be loaded.
    #[error("failed to load RKMPI library from {path}: {source}")]
    LibraryLoad {
        /// Library path attempted.
        path: PathBuf,
        /// Loading error.
        source: libloading::Error,
    },

    /// A required symbol was not found in the RKMPI library.
    #[error("RKMPI symbol {symbol} not found: {source}")]
    Symbol {
        /// Symbol name.
        symbol: &'static str,
        /// Loading error.
        source: libloading::Error,
    },

    /// `RK_MPI_SYS_Init` failed.
    #[error("RK_MPI_SYS_Init failed with code {code}")]
    SysInit {
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_CreateChn` failed.
    #[error("RK_MPI_VENC_CreateChn({channel}) failed with code {code}")]
    CreateChannel {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_StartRecvFrame` failed.
    #[error("RK_MPI_VENC_StartRecvFrame({channel}) failed with code {code}")]
    StartRecv {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_SendFrame` failed.
    #[error("RK_MPI_VENC_SendFrame({channel}) failed with code {code}")]
    SendFrame {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_GetStream` failed or timed out.
    #[error("RK_MPI_VENC_GetStream({channel}) failed with code {code}")]
    GetStream {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_RequestIDR` failed.
    #[error("RK_MPI_VENC_RequestIDR({channel}) failed with code {code}")]
    RequestIdr {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// `RK_MPI_VENC_SetRcParam` failed (bitrate adjustment).
    #[error("RK_MPI_VENC_SetRcParam({channel}) failed with code {code}")]
    SetRcParam {
        /// VENC channel number.
        channel: i32,
        /// RKMPI error code.
        code: i32,
    },

    /// The encoded output contained no packet data.
    #[error("encoder returned empty packet on channel {channel}")]
    EmptyPacket {
        /// VENC channel number.
        channel: i32,
    },

    /// Frame dimensions do not match the encoder configuration.
    #[error(
        "frame size mismatch: encoder configured for {expected_width}x{expected_height}, \
         got {actual_width}x{actual_height}"
    )]
    FrameSizeMismatch {
        /// Configured width.
        expected_width: u32,
        /// Configured height.
        expected_height: u32,
        /// Actual frame width.
        actual_width: u32,
        /// Actual frame height.
        actual_height: u32,
    },
}
