//! RKNN NPU runtime FFI bindings.
//!
//! Wraps `librknnmrt.so` (Rockchip NPU runtime for RV1106) via `libloading`
//! for dynamic loading at runtime. Provides [`Model`] for loading `.rknn`
//! models and running zero-copy inference on the NPU.
//!
//! All unsafe code in this module is covered by ADR-002.

use std::ffi::c_void;
use std::os::fd::{BorrowedFd, RawFd};
use std::path::Path;
use std::ptr;

use super::error::NpuError;
use super::tensor::{OutputTensor, QuantType, TensorAttr, TensorFormat, TensorType};
use super::{ModelPriority, NpuConfig};

// ---------------------------------------------------------------------------
// RKNN constants from rknn_api.h
// ---------------------------------------------------------------------------

/// Successful return code from all RKNN API calls.
const RKNN_SUCC: i32 = 0;

// --- rknn_context type (platform-dependent) ---

/// RKNN context handle. `uint32_t` on 32-bit ARM, `uint64_t` on 64-bit.
#[cfg(target_pointer_width = "32")]
pub(super) type RknnContext = u32;

/// RKNN context handle. `uint32_t` on 32-bit ARM, `uint64_t` on 64-bit.
#[cfg(target_pointer_width = "64")]
pub(super) type RknnContext = u64;

// --- Query commands (rknn_query_cmd) ---

/// `RKNN_QUERY_IN_OUT_NUM` — query input/output tensor counts.
const RKNN_QUERY_IN_OUT_NUM: u32 = 0;

/// `RKNN_QUERY_NATIVE_INPUT_ATTR` — query NPU-native input tensor layout.
const RKNN_QUERY_NATIVE_INPUT_ATTR: u32 = 8;

/// `RKNN_QUERY_NATIVE_OUTPUT_ATTR` — query NPU-native output tensor layout.
const RKNN_QUERY_NATIVE_OUTPUT_ATTR: u32 = 9;

// --- Init flags (rknn_init flag bitfield) ---

/// `RKNN_FLAG_MEM_ALLOC_OUTSIDE` — caller manages I/O memory (zero-copy path).
const RKNN_FLAG_MEM_ALLOC_OUTSIDE: u32 = 0x10;

// --- Memory sync modes (rknn_mem_sync_mode) ---

/// `RKNN_MEM_SYNC_TO_CPU` — invalidate CPU cache after NPU writes (output path).
const RKNN_MEM_SYNC_TO_CPU: u32 = 1;

// --- Struct dimension limits ---

/// `RKNN_MAX_DIMS` — maximum tensor dimensions.
const RKNN_MAX_DIMS: usize = 16;

/// `RKNN_MAX_NAME_LEN` — maximum tensor name string length.
const RKNN_MAX_NAME_LEN: usize = 256;

// --- Query struct sizes (compile-time constants for FFI) ---

#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "size_of::<RknnInputOutputNum>() is 8 bytes, trivially fits u32"
)]
const IO_NUM_QUERY_SIZE: u32 = size_of::<RknnInputOutputNum>() as u32;

#[expect(
    clippy::as_conversions,
    clippy::cast_possible_truncation,
    reason = "size_of::<RknnTensorAttr>() is ~360 bytes, trivially fits u32"
)]
const TENSOR_ATTR_QUERY_SIZE: u32 = size_of::<RknnTensorAttr>() as u32;

// ---------------------------------------------------------------------------
// C-ABI structs from rknn_api.h (#[repr(C)])
// ---------------------------------------------------------------------------

/// `rknn_input_output_num` — model I/O tensor counts.
#[repr(C)]
#[derive(Debug, Clone)]
struct RknnInputOutputNum {
    n_input: u32,
    n_output: u32,
}

impl RknnInputOutputNum {
    const fn zeroed() -> Self {
        Self {
            n_input: 0,
            n_output: 0,
        }
    }
}

/// `rknn_tensor_attr` — tensor metadata including shape, type, and quantization.
#[repr(C)]
#[derive(Clone)]
struct RknnTensorAttr {
    index: u32,
    n_dims: u32,
    dims: [u32; RKNN_MAX_DIMS],
    name: [i8; RKNN_MAX_NAME_LEN],
    n_elems: u32,
    size: u32,
    fmt: u32,
    type_: u32,
    qnt_type: u32,
    zp: i32,
    scale: f32,
    w_stride: u32,
    size_with_stride: u32,
    pass_through: u8,
    h_stride: u32,
}

impl RknnTensorAttr {
    const fn zeroed() -> Self {
        Self {
            index: 0,
            n_dims: 0,
            dims: [0_u32; RKNN_MAX_DIMS],
            name: [0_i8; RKNN_MAX_NAME_LEN],
            n_elems: 0,
            size: 0,
            fmt: 0,
            type_: 0,
            qnt_type: 0,
            zp: 0,
            scale: 0.0_f32,
            w_stride: 0,
            size_with_stride: 0,
            pass_through: 0,
            h_stride: 0,
        }
    }

    /// Converts to the safe [`TensorAttr`] type.
    fn to_tensor_attr(&self) -> TensorAttr {
        TensorAttr {
            index: self.index,
            n_dims: self.n_dims,
            dims: self.dims,
            n_elems: self.n_elems,
            size: self.size,
            format: TensorFormat::from_raw(self.fmt),
            data_type: TensorType::from_raw(self.type_),
            qnt_type: QuantType::from_raw(self.qnt_type),
            zp: self.zp,
            scale: self.scale,
            w_stride: self.w_stride,
            size_with_stride: self.size_with_stride,
            h_stride: self.h_stride,
        }
    }
}

impl std::fmt::Debug for RknnTensorAttr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let n = usize::try_from(self.n_dims).unwrap_or(0).min(RKNN_MAX_DIMS);
        f.debug_struct("RknnTensorAttr")
            .field("index", &self.index)
            .field("n_dims", &self.n_dims)
            .field("dims", &self.dims.get(..n).unwrap_or(&[]))
            .field("fmt", &self.fmt)
            .field("type", &self.type_)
            .field("qnt_type", &self.qnt_type)
            .field("zp", &self.zp)
            .field("scale", &self.scale)
            .field("size_with_stride", &self.size_with_stride)
            .finish_non_exhaustive()
    }
}

/// `rknn_tensor_mem` — NPU DMA buffer descriptor.
///
/// Allocated by `rknn_create_mem`. Contains both CPU-accessible (`virt_addr`)
/// and DMA (`fd`, `phys_addr`) handles to the same memory.
#[repr(C)]
struct RknnTensorMem {
    virt_addr: *mut c_void,
    phys_addr: u64,
    fd: i32,
    offset: i32,
    size: u32,
    flags: u32,
    priv_data: *mut c_void,
}

// ---------------------------------------------------------------------------
// Function pointer types matching rknn_api.h signatures
// ---------------------------------------------------------------------------

/// `rknn_init(context, model, size, flag, extend) -> int`
type FnRknnInit = unsafe extern "C" fn(
    context: *mut RknnContext,
    model: *const c_void,
    size: u32,
    flag: u32,
    extend: *const c_void,
) -> i32;

/// `rknn_query(context, cmd, info, size) -> int`
type FnRknnQuery =
    unsafe extern "C" fn(context: RknnContext, cmd: u32, info: *mut c_void, size: u32) -> i32;

/// `rknn_run(context, extend) -> int`
type FnRknnRun = unsafe extern "C" fn(context: RknnContext, extend: *const c_void) -> i32;

/// `rknn_destroy(context) -> int`
type FnRknnDestroy = unsafe extern "C" fn(context: RknnContext) -> i32;

/// `rknn_create_mem(ctx, size) -> *mut rknn_tensor_mem`
type FnRknnCreateMem = unsafe extern "C" fn(ctx: RknnContext, size: u32) -> *mut RknnTensorMem;

/// `rknn_destroy_mem(ctx, mem) -> int`
type FnRknnDestroyMem = unsafe extern "C" fn(ctx: RknnContext, mem: *mut RknnTensorMem) -> i32;

/// `rknn_set_io_mem(ctx, mem, attr) -> int`
type FnRknnSetIoMem = unsafe extern "C" fn(
    ctx: RknnContext,
    mem: *mut RknnTensorMem,
    attr: *mut RknnTensorAttr,
) -> i32;

/// `rknn_mem_sync(ctx, mem, mode) -> int`
type FnRknnMemSync =
    unsafe extern "C" fn(ctx: RknnContext, mem: *mut RknnTensorMem, mode: u32) -> i32;

// ---------------------------------------------------------------------------
// Loaded library handle
// ---------------------------------------------------------------------------

/// Resolved function pointers from `librknnmrt.so`.
struct RknnLibrary {
    _lib: libloading::Library,
    rknn_init: FnRknnInit,
    rknn_query: FnRknnQuery,
    rknn_run: FnRknnRun,
    rknn_destroy: FnRknnDestroy,
    rknn_create_mem: FnRknnCreateMem,
    rknn_destroy_mem: FnRknnDestroyMem,
    rknn_set_io_mem: FnRknnSetIoMem,
    rknn_mem_sync: FnRknnMemSync,
}

impl std::fmt::Debug for RknnLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RknnLibrary").finish_non_exhaustive()
    }
}

/// Loads a single typed symbol from a `libloading::Library`.
macro_rules! load_symbol {
    ($lib:expr, $fn_type:ty, $name:literal) => {{
        #[expect(
            unsafe_code,
            clippy::undocumented_unsafe_blocks,
            reason = "libloading symbol lookup — ADR-002. SAFETY: symbol name matches \
                      rknn_api.h; function pointer valid for Library lifetime."
        )]
        let sym: libloading::Symbol<'_, $fn_type> = unsafe {
            $lib.get(concat!($name, "\0").as_bytes())
        }
        .map_err(|source| NpuError::Symbol {
            symbol: $name,
            source,
        })?;
        *sym
    }};
}

impl RknnLibrary {
    /// Loads `librknnmrt.so` and resolves all required RKNN API symbols.
    fn load(lib_path: &Path) -> Result<Self, NpuError> {
        #[expect(
            unsafe_code,
            reason = "libloading::Library::new loads a shared object — ADR-002"
        )]
        // SAFETY: loading the RKNN runtime library from a user-configured path.
        // Defaults to /usr/lib/librknnmrt.so on the target device.
        let lib = unsafe { libloading::Library::new(lib_path) }.map_err(|source| {
            NpuError::LibraryLoad {
                path: lib_path.to_path_buf(),
                source,
            }
        })?;

        let rknn_init = load_symbol!(lib, FnRknnInit, "rknn_init");
        let rknn_query = load_symbol!(lib, FnRknnQuery, "rknn_query");
        let rknn_run = load_symbol!(lib, FnRknnRun, "rknn_run");
        let rknn_destroy = load_symbol!(lib, FnRknnDestroy, "rknn_destroy");
        let rknn_create_mem = load_symbol!(lib, FnRknnCreateMem, "rknn_create_mem");
        let rknn_destroy_mem = load_symbol!(lib, FnRknnDestroyMem, "rknn_destroy_mem");
        let rknn_set_io_mem = load_symbol!(lib, FnRknnSetIoMem, "rknn_set_io_mem");
        let rknn_mem_sync = load_symbol!(lib, FnRknnMemSync, "rknn_mem_sync");

        Ok(Self {
            _lib: lib,
            rknn_init,
            rknn_query,
            rknn_run,
            rknn_destroy,
            rknn_create_mem,
            rknn_destroy_mem,
            rknn_set_io_mem,
            rknn_mem_sync,
        })
    }
}

// ---------------------------------------------------------------------------
// Bound tensor memory (private)
// ---------------------------------------------------------------------------

/// An output tensor's DMA memory and parsed metadata.
struct BoundOutput {
    mem: *mut RknnTensorMem,
    attr: TensorAttr,
}

// ---------------------------------------------------------------------------
// Model — safe public API over the RKNN lifecycle
// ---------------------------------------------------------------------------

/// A loaded RKNN model with pre-allocated zero-copy I/O memory.
///
/// Manages the full lifecycle: model loading, I/O memory allocation and
/// binding, inference execution, cache synchronization, and cleanup.
///
/// # Lifecycle
///
/// ```text
/// Model::load(config, model_data, priority)
///   → set_input(data) — write input, sync CPU→device
///   → run()           — NPU inference, sync outputs device→CPU
///   → output(index)   — read output tensor data
///   → [Drop destroys memory and context]
/// ```
pub(crate) struct Model {
    lib: RknnLibrary,
    ctx: RknnContext,
    input_mem: *mut RknnTensorMem,
    input_attr: TensorAttr,
    input_fd: RawFd,
    outputs: Vec<BoundOutput>,
}

impl std::fmt::Debug for Model {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Model")
            .field("input_attr", &self.input_attr)
            .field("output_count", &self.outputs.len())
            .finish_non_exhaustive()
    }
}

impl Model {
    /// Loads an RKNN model, queries tensor attributes, and allocates zero-copy
    /// I/O memory bound to the NPU.
    ///
    /// `model_data` is the raw bytes of an `.rknn` file (read into memory).
    /// The model is initialized with `RKNN_FLAG_MEM_ALLOC_OUTSIDE` for the
    /// zero-copy DMA buffer path.
    #[tracing::instrument(skip_all, fields(
        model_size = model_data.len(),
        priority = ?priority,
    ))]
    pub(crate) fn load(
        config: &NpuConfig,
        model_data: &[u8],
        priority: ModelPriority,
    ) -> Result<Self, NpuError> {
        let lib = RknnLibrary::load(&config.lib_path)?;

        // Initialize model context with zero-copy flag.
        let ctx = Self::init_context(&lib, model_data, priority)?;

        // Create partially-initialized Model. Drop handles cleanup on error.
        let mut model = Self {
            lib,
            ctx,
            input_mem: ptr::null_mut(),
            input_attr: TensorAttr::empty(),
            input_fd: -1_i32,
            outputs: Vec::new(),
        };

        model.setup_io()?;

        tracing::info!(
            outputs = model.outputs.len(),
            input_size = model.input_attr.size_with_stride(),
            "RKNN model loaded"
        );

        Ok(model)
    }

    /// Writes input data to the NPU's DMA buffer.
    ///
    /// `data` must be exactly `input_attr().size_with_stride()` bytes, in the
    /// format expected by the model (typically NHWC uint8 RGB).
    pub(crate) fn set_input(&mut self, data: &[u8]) -> Result<(), NpuError> {
        let expected = self.input_attr.size_with_stride();
        let actual = u32::try_from(data.len()).unwrap_or(u32::MAX);
        if actual != expected {
            return Err(NpuError::InputSizeMismatch { expected, actual });
        }

        // Copy input data into the DMA buffer.
        #[expect(
            unsafe_code,
            reason = "accessing virt_addr from RKNN input tensor — ADR-002"
        )]
        // SAFETY: self.input_mem is a valid rknn_tensor_mem from rknn_create_mem.
        // virt_addr is a CPU-writable pointer to DMA memory.
        let dst = unsafe { (*self.input_mem).virt_addr };

        #[expect(
            unsafe_code,
            clippy::semicolon_outside_block,
            reason = "copying input data to NPU DMA buffer — ADR-002"
        )]
        // SAFETY: dst points to at least `expected` bytes of writable DMA memory.
        // data.len() == expected (validated above). Regions don't overlap (DMA
        // memory is kernel-allocated, separate from userspace heap).
        unsafe {
            ptr::copy_nonoverlapping(data.as_ptr(), dst.cast::<u8>(), data.len());
        }

        Ok(())
    }

    /// Runs NPU inference and synchronizes output buffers.
    ///
    /// After this returns, output tensor data is readable via [`output`](Self::output).
    /// The input must have been set via [`set_input`](Self::set_input) first.
    pub(crate) fn run(&mut self) -> Result<(), NpuError> {
        // Execute inference on the NPU.
        #[expect(unsafe_code, reason = "RKNN FFI: rknn_run — ADR-002")]
        // SAFETY: self.ctx is a valid context with bound I/O memory.
        // Input data has been written via set_input. Null extend is accepted.
        let ret = unsafe { (self.lib.rknn_run)(self.ctx, ptr::null()) };

        if ret != RKNN_SUCC {
            return Err(NpuError::Run { code: ret });
        }

        // Sync all output buffers: invalidate CPU cache to see NPU writes.
        // Required on RV1106 for cache coherency in zero-copy mode.
        self.sync_outputs()?;

        Ok(())
    }

    /// Returns a view of the output tensor at `index`.
    ///
    /// The returned [`OutputTensor`] borrows from this model, ensuring the
    /// DMA buffer remains valid. Data is raw INT8 in the NPU's native layout
    /// (typically NC1HWC2 with C2=16).
    pub(crate) fn output(&self, index: u32) -> Result<OutputTensor<'_>, NpuError> {
        let idx = usize::try_from(index).unwrap_or(usize::MAX);
        let output = self
            .outputs
            .get(idx)
            .ok_or(NpuError::OutputIndexOutOfRange {
                index,
                count: self.output_count(),
            })?;

        let size = usize::try_from(output.attr.size_with_stride()).unwrap_or(0);

        #[expect(
            unsafe_code,
            reason = "reading virt_addr from RKNN output tensor — ADR-002"
        )]
        // SAFETY: output.mem is a valid rknn_tensor_mem from rknn_create_mem.
        // virt_addr is a CPU-readable pointer to DMA memory.
        let virt_addr = unsafe { (*output.mem).virt_addr };

        #[expect(
            unsafe_code,
            reason = "constructing slice from NPU output DMA buffer — ADR-002"
        )]
        // SAFETY: virt_addr points to at least `size` bytes of NPU-written data.
        // rknn_mem_sync(TO_CPU) was called in run() to ensure cache coherency.
        // The lifetime is tied to &self, which owns the tensor memory. No
        // concurrent writes occur because run() requires &mut self.
        let data = unsafe { std::slice::from_raw_parts(virt_addr.cast::<i8>(), size) };

        Ok(OutputTensor::new(data, &output.attr))
    }

    /// Number of output tensors in this model.
    pub(crate) fn output_count(&self) -> u32 {
        u32::try_from(self.outputs.len()).unwrap_or(u32::MAX)
    }

    /// Input tensor metadata (shape, format, expected size).
    pub(crate) fn input_attr(&self) -> &TensorAttr {
        &self.input_attr
    }

    /// Output tensor metadata at `index`.
    pub(crate) fn output_attr(&self, index: u32) -> Result<&TensorAttr, NpuError> {
        let idx = usize::try_from(index).unwrap_or(usize::MAX);
        self.outputs
            .get(idx)
            .map(|o| &o.attr)
            .ok_or(NpuError::OutputIndexOutOfRange {
                index,
                count: self.output_count(),
            })
    }

    /// DMA-BUF file descriptor for the input tensor memory.
    ///
    /// Can be passed to RGA for zero-copy hardware-accelerated format
    /// conversion (e.g. NV12 to RGB) directly into the NPU input buffer.
    pub(crate) fn input_fd(&self) -> BorrowedFd<'_> {
        #[expect(
            unsafe_code,
            reason = "creating BorrowedFd from RKNN DMA buffer fd — ADR-002"
        )]
        // SAFETY: self.input_fd is a valid DMA-BUF fd from rknn_create_mem.
        // The fd lives as long as self (destroyed in Drop). BorrowedFd's
        // lifetime is tied to &self.
        unsafe {
            BorrowedFd::borrow_raw(self.input_fd)
        }
    }

    // -----------------------------------------------------------------------
    // Private: model initialization
    // -----------------------------------------------------------------------

    /// Initializes the RKNN model context from in-memory model data.
    fn init_context(
        lib: &RknnLibrary,
        model_data: &[u8],
        priority: ModelPriority,
    ) -> Result<RknnContext, NpuError> {
        let model_size =
            u32::try_from(model_data.len()).map_err(|_err| NpuError::Init { code: -1_i32 })?;

        let flags = RKNN_FLAG_MEM_ALLOC_OUTSIDE | priority.flag();

        let mut ctx: RknnContext = 0;

        #[expect(unsafe_code, reason = "RKNN FFI: rknn_init — ADR-002")]
        // SAFETY: ctx is a valid pointer to a stack variable. model_data.as_ptr()
        // points to model_size bytes of model data. Null extend is accepted.
        let ret = unsafe {
            (lib.rknn_init)(
                &raw mut ctx,
                model_data.as_ptr().cast::<c_void>(),
                model_size,
                flags,
                ptr::null(),
            )
        };

        if ret != RKNN_SUCC {
            return Err(NpuError::Init { code: ret });
        }

        tracing::debug!("RKNN context initialized");
        Ok(ctx)
    }

    /// Queries tensor attributes and allocates/binds all I/O memory.
    fn setup_io(&mut self) -> Result<(), NpuError> {
        // Query model topology.
        let io_num = self.query_io_num()?;

        if io_num.n_input == 0 || io_num.n_output == 0 {
            return Err(NpuError::InvalidModelTopology {
                n_input: io_num.n_input,
                n_output: io_num.n_output,
            });
        }

        tracing::debug!(
            inputs = io_num.n_input,
            outputs = io_num.n_output,
            "model topology"
        );

        // --- Input ---

        let mut input_raw =
            self.query_native_attr(RKNN_QUERY_NATIVE_INPUT_ATTR, "NATIVE_INPUT_ATTR", 0)?;

        self.input_mem = self.alloc_mem(input_raw.size_with_stride, "input 0")?;

        // Skip runtime format conversion — we provide data in native layout.
        input_raw.pass_through = 1;
        self.bind_io_mem(self.input_mem, &mut input_raw, "input 0")?;

        // Extract DMA-BUF fd for future RGA integration.
        #[expect(
            unsafe_code,
            reason = "reading fd from RKNN input tensor memory — ADR-002"
        )]
        // SAFETY: self.input_mem is a valid rknn_tensor_mem from rknn_create_mem.
        let fd = unsafe { (*self.input_mem).fd };
        self.input_fd = fd;

        self.input_attr = input_raw.to_tensor_attr();
        tracing::debug!(attr = ?self.input_attr, "input tensor bound");

        // --- Outputs ---

        let n_output = io_num.n_output;
        self.outputs.reserve(usize::try_from(n_output).unwrap_or(0));

        for i in 0..n_output {
            let mut raw =
                self.query_native_attr(RKNN_QUERY_NATIVE_OUTPUT_ATTR, "NATIVE_OUTPUT_ATTR", i)?;

            let mem = self.alloc_mem(raw.size_with_stride, &format!("output {i}"))?;

            raw.pass_through = 1;
            self.bind_io_mem(mem, &mut raw, &format!("output {i}"))?;

            let attr = raw.to_tensor_attr();
            tracing::debug!(index = i, attr = ?attr, "output tensor bound");

            self.outputs.push(BoundOutput { mem, attr });
        }

        Ok(())
    }

    // -----------------------------------------------------------------------
    // Private: RKNN API wrappers
    // -----------------------------------------------------------------------

    fn query_io_num(&self) -> Result<RknnInputOutputNum, NpuError> {
        let mut io_num = RknnInputOutputNum::zeroed();

        #[expect(unsafe_code, reason = "RKNN FFI: rknn_query IN_OUT_NUM — ADR-002")]
        // SAFETY: self.ctx is valid. io_num is a zeroed struct of correct size.
        let ret = unsafe {
            (self.lib.rknn_query)(
                self.ctx,
                RKNN_QUERY_IN_OUT_NUM,
                (&raw mut io_num).cast(),
                IO_NUM_QUERY_SIZE,
            )
        };

        if ret != RKNN_SUCC {
            return Err(NpuError::Query {
                command: "IN_OUT_NUM",
                code: ret,
            });
        }

        Ok(io_num)
    }

    fn query_native_attr(
        &self,
        cmd: u32,
        cmd_name: &'static str,
        index: u32,
    ) -> Result<RknnTensorAttr, NpuError> {
        let mut attr = RknnTensorAttr::zeroed();
        attr.index = index;

        #[expect(unsafe_code, reason = "RKNN FFI: rknn_query tensor attr — ADR-002")]
        // SAFETY: self.ctx is valid. attr is zeroed with index set. Size matches.
        let ret = unsafe {
            (self.lib.rknn_query)(
                self.ctx,
                cmd,
                (&raw mut attr).cast(),
                TENSOR_ATTR_QUERY_SIZE,
            )
        };

        if ret != RKNN_SUCC {
            return Err(NpuError::Query {
                command: cmd_name,
                code: ret,
            });
        }

        Ok(attr)
    }

    fn alloc_mem(&self, size: u32, purpose: &str) -> Result<*mut RknnTensorMem, NpuError> {
        #[expect(unsafe_code, reason = "RKNN FFI: rknn_create_mem — ADR-002")]
        // SAFETY: self.ctx is a valid initialized context. size is from a
        // queried tensor attr (size_with_stride).
        let mem = unsafe { (self.lib.rknn_create_mem)(self.ctx, size) };

        if mem.is_null() {
            return Err(NpuError::MemAlloc {
                purpose: String::from(purpose),
                size,
            });
        }

        Ok(mem)
    }

    fn bind_io_mem(
        &self,
        mem: *mut RknnTensorMem,
        attr: &mut RknnTensorAttr,
        purpose: &str,
    ) -> Result<(), NpuError> {
        #[expect(unsafe_code, reason = "RKNN FFI: rknn_set_io_mem — ADR-002")]
        // SAFETY: self.ctx is valid. mem is a valid rknn_tensor_mem from
        // rknn_create_mem. attr has pass_through set and correct index.
        let ret = unsafe { (self.lib.rknn_set_io_mem)(self.ctx, mem, &raw mut *attr) };

        if ret != RKNN_SUCC {
            return Err(NpuError::MemBind {
                purpose: String::from(purpose),
                code: ret,
            });
        }

        Ok(())
    }

    fn sync_outputs(&self) -> Result<(), NpuError> {
        for (i, output) in self.outputs.iter().enumerate() {
            let index = u32::try_from(i).unwrap_or(u32::MAX);

            #[expect(unsafe_code, reason = "RKNN FFI: rknn_mem_sync output — ADR-002")]
            // SAFETY: self.ctx is valid. output.mem is a valid tensor memory.
            // RKNN_MEM_SYNC_TO_CPU invalidates CPU cache to see NPU writes.
            let ret =
                unsafe { (self.lib.rknn_mem_sync)(self.ctx, output.mem, RKNN_MEM_SYNC_TO_CPU) };

            if ret != RKNN_SUCC {
                return Err(NpuError::MemSync { index, code: ret });
            }
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

impl Drop for Model {
    fn drop(&mut self) {
        // Destroy output tensor memories.
        for output in &self.outputs {
            if !output.mem.is_null() {
                #[expect(unsafe_code, reason = "RKNN FFI: rknn_destroy_mem output — ADR-002")]
                // SAFETY: self.ctx is valid. output.mem was allocated by rknn_create_mem.
                unsafe {
                    (self.lib.rknn_destroy_mem)(self.ctx, output.mem);
                }
            }
        }

        // Destroy input tensor memory.
        if !self.input_mem.is_null() {
            #[expect(unsafe_code, reason = "RKNN FFI: rknn_destroy_mem input — ADR-002")]
            // SAFETY: self.ctx is valid. self.input_mem was allocated by rknn_create_mem.
            unsafe {
                (self.lib.rknn_destroy_mem)(self.ctx, self.input_mem);
            }
        }

        // Destroy the model context.
        #[expect(
            unsafe_code,
            clippy::semicolon_outside_block,
            reason = "RKNN FFI: rknn_destroy — ADR-002"
        )]
        // SAFETY: self.ctx is valid. After this, the context must not be used
        // again (but we're in Drop, so it won't be).
        unsafe {
            (self.lib.rknn_destroy)(self.ctx);
        }

        tracing::debug!("RKNN model destroyed");
    }
}

// Raw pointers in Model (*mut RknnTensorMem) point to stable kernel-managed
// DMA buffers allocated by rknn_create_mem. Moving the struct between threads
// is safe because the DMA mappings don't move and access is synchronized by
// the &mut self requirement on set_input/run.
#[expect(
    unsafe_code,
    reason = "Model's raw pointers are to stable RKNN DMA memory — ADR-002"
)]
// SAFETY: see comment above. All mutable operations on the DMA buffers
// require &mut self, preventing concurrent access.
unsafe impl Send for Model {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn test_load_missing_library() {
        let result = RknnLibrary::load(Path::new("/nonexistent/librknnmrt.so"));
        let Err(err) = result else {
            #[expect(clippy::panic, reason = "test assertion")]
            {
                panic!("loading from nonexistent path must fail");
            }
        };
        assert!(
            matches!(err, NpuError::LibraryLoad { .. }),
            "error must be LibraryLoad, got: {err}"
        );
    }

    #[test]
    fn test_rknn_tensor_attr_zeroed() {
        let attr = RknnTensorAttr::zeroed();
        assert_eq!(attr.index, 0, "zeroed index");
        assert_eq!(attr.n_dims, 0, "zeroed n_dims");
        assert_eq!(attr.size_with_stride, 0, "zeroed size_with_stride");
        assert_eq!(attr.pass_through, 0, "zeroed pass_through");
    }

    #[test]
    fn test_rknn_tensor_attr_to_tensor_attr() {
        let mut raw = RknnTensorAttr::zeroed();
        raw.index = 3;
        raw.n_dims = 4;
        raw.dims[0] = 1;
        raw.dims[1] = 80;
        raw.dims[2] = 80;
        raw.dims[3] = 16;
        raw.n_elems = 102_400;
        raw.size = 102_400;
        raw.fmt = 2; // NC1HWC2
        raw.type_ = 2; // INT8
        raw.qnt_type = 2; // AffineAsymmetric
        raw.zp = -128_i32;
        raw.scale = 0.003_452_f32;
        raw.w_stride = 80;
        raw.size_with_stride = 102_400;
        raw.h_stride = 0;

        let attr = raw.to_tensor_attr();
        assert_eq!(attr.index(), 3, "index");
        assert_eq!(attr.n_dims(), 4, "n_dims");
        assert_eq!(attr.dims(), &[1, 80, 80, 16], "dims");
        assert_eq!(attr.n_elems(), 102_400, "n_elems");
        assert_eq!(attr.format(), TensorFormat::Nc1hwc2, "format");
        assert_eq!(attr.data_type(), TensorType::Int8, "data_type");
        assert_eq!(attr.qnt_type(), QuantType::AffineAsymmetric, "qnt_type");
        assert_eq!(attr.zp(), -128_i32, "zp");
        assert_eq!(attr.size_with_stride(), 102_400, "size_with_stride");
    }

    #[test]
    fn test_io_num_zeroed() {
        let io = RknnInputOutputNum::zeroed();
        assert_eq!(io.n_input, 0, "zeroed n_input");
        assert_eq!(io.n_output, 0, "zeroed n_output");
    }

    #[test]
    fn test_model_load_missing_library() {
        let config = NpuConfig {
            lib_path: std::path::PathBuf::from("/nonexistent/librknnmrt.so"),
        };
        let result = Model::load(&config, &[0_u8; 64], ModelPriority::High);
        assert!(result.is_err(), "load must fail when library is absent");
    }
}
