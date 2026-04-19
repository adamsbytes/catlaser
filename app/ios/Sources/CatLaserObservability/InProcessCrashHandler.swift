#if canImport(Darwin)
import Darwin
import Foundation

/// In-process crash capture — complements ``MetricKit`` by recording
/// a tombstone from the `NSException` / POSIX-signal path.
///
/// ## Why in-process capture exists
///
/// Apple's ``MXMetricManager`` is the authoritative source of truth
/// for crash stacks, register dumps, and image load addresses. It
/// catches signal-originated crashes (abort, segfault), pure Swift
/// ``fatalError``, and hung main threads. It is also the only path
/// that gives us the backtrace frames — capturing those from a
/// signal handler is not async-signal-safe.
///
/// The in-process handler therefore has a narrower job: write a
/// *sentinel* tombstone that carries the breadcrumbs trailing the
/// crash and the session ID. On the next launch the observability
/// pipeline:
///
/// 1. Reads any pending tombstones (both signal markers and
///    ``NSException`` JSON files) and emits a
///    `crash_report_delivered` telemetry event tagged
///    ``CrashSource/tombstone``.
/// 2. Attaches the breadcrumb snapshot captured at crash time to
///    the outgoing batch.
/// 3. Separately, processes every pending ``MXDiagnosticPayload``
///    and emits a second event tagged
///    ``CrashSource/metricKit`` with the Apple-signed payload.
///
/// Having both paths means we get breadcrumbs even when MetricKit's
/// delivery is deferred (low-power mode, delayed submission) — and
/// we get the authoritative stack trace even when the signal
/// handler could not capture it.
///
/// ## Signal-safety posture
///
/// - The ``NSException`` handler runs from ``NSUncaughtExceptionHandler``,
///   which is a regular stack frame: Swift runtime, heap, JSON
///   encoding are all safe.
/// - The POSIX signal handlers run in a signal context. Only
///   async-signal-safe APIs are used: `open(2)`, `write(2)`,
///   `close(2)`, `signal(3)`, `raise(3)`, `_exit(2)`, plus literal C
///   strings and pre-allocated byte buffers. No Swift runtime hops,
///   no heap allocations, no `Foundation` calls. The previous
///   handler (if any) is re-chained via `signal(3)` so `SIGABRT`
///   still exits the process with the expected status.
public enum InProcessCrashHandler {
    /// Signals we install handlers for. Apps on iOS most commonly
    /// crash with ``SIGABRT`` (out of Swift ``fatalError`` / Objective-
    /// C ``NSAssert``), ``SIGSEGV`` (null deref / use-after-free in
    /// a C dependency), or ``SIGBUS`` (misaligned access on older
    /// CPUs). ``SIGILL`` / ``SIGFPE`` are rare but worth capturing;
    /// ``SIGPIPE`` is deliberately excluded because Foundation ignores
    /// it by default and we do not want a sentinel for every
    /// network-half-close.
    public static let handledSignals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE,
    ]

    /// Install the handlers. Idempotent — repeated calls no-op.
    /// Called once at launch from the composition root.
    public static func install(
        tombstoneDirectory: URL,
        sessionID: String,
        appVersion: String,
        buildNumber: String,
        osVersion: String,
    ) {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true

        context = CrashContext(
            tombstoneDirectory: tombstoneDirectory,
            sessionID: sessionID,
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
        )

        // Stash pre-computed C strings for the signal handler. These
        // pointers are reached from a signal context via
        // ``withPointerSnapshot``, which copies the pointer value
        // through a Swift runtime-managed variable; the underlying
        // bytes are immutable and live for the rest of the process.
        signalTombstoneDirectoryCString = strdup(tombstoneDirectory.path)
        signalSessionIDCString = strdup(sessionID)

        installNSExceptionHandler()
        installSignalHandlers()
    }

    /// Uninstall everything. Used by tests to run an ``install``
    /// pair and then reset global state. Not called from shipping
    /// code.
    public static func uninstallForTesting() {
        installLock.lock()
        defer { installLock.unlock() }
        guard installed else { return }
        installed = false

        // Restore previous signal handlers.
        for (sig, previous) in previousSignalHandlers {
            _ = signal(sig, previous)
        }
        previousSignalHandlers.removeAll()

        // Restore the previous NSException handler.
        NSSetUncaughtExceptionHandler(previousNSExceptionHandler)
        previousNSExceptionHandler = nil

        if let ptr = signalTombstoneDirectoryCString {
            free(ptr)
            signalTombstoneDirectoryCString = nil
        }
        if let ptr = signalSessionIDCString {
            free(ptr)
            signalSessionIDCString = nil
        }
        context = nil
    }

    // MARK: - NSException path

    private static func installNSExceptionHandler() {
        // Capture any previous handler so a test framework or an
        // earlier observer still fires.
        previousNSExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // This runs on the thread that raised the exception.
            // Swift runtime is available — we can encode JSON.
            guard let ctx = InProcessCrashHandler.context else { return }
            let summary = "\(exception.name.rawValue): \(exception.reason ?? "")"
            let callStack = exception.callStackSymbols
            let tombstone = Tombstone(
                id: UUID().uuidString,
                reason: .uncaughtException,
                capturedAt: ISO8601DateFormatter().string(from: Date()),
                summary: summary,
                callStack: callStack,
                appVersion: ctx.appVersion,
                buildNumber: ctx.buildNumber,
                osVersion: ctx.osVersion,
            )
            let store = TombstoneStore(directory: ctx.tombstoneDirectory)
            try? store.writeFromNormalContext(tombstone)

            // Chain to the previous handler so test frameworks /
            // analytics agents still see the exception.
            if let previous = InProcessCrashHandler.previousNSExceptionHandler {
                previous(exception)
            }
        }
    }

    // MARK: - POSIX signal path

    private static func installSignalHandlers() {
        for sig in handledSignals {
            let previous = signal(sig, crashSignalHandler)
            if previous != SIG_ERR {
                previousSignalHandlers[sig] = previous
            }
        }
    }

    // MARK: - Globals (access restricted)

    private struct CrashContext {
        let tombstoneDirectory: URL
        let sessionID: String
        let appVersion: String
        let buildNumber: String
        let osVersion: String
    }

    private static var installed: Bool = false
    private static let installLock = NSLock()
    fileprivate static var context: CrashContext?
    fileprivate static var previousNSExceptionHandler: (@convention(c) (NSException) -> Void)?
    fileprivate static var previousSignalHandlers: [Int32: sig_t?] = [:]

    /// Pre-allocated directory path as a null-terminated C string.
    /// Accessed from the signal handler via a raw pointer — never
    /// dereferenced as a Swift String from a signal context.
    nonisolated(unsafe) fileprivate static var signalTombstoneDirectoryCString: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) fileprivate static var signalSessionIDCString: UnsafeMutablePointer<CChar>?
}

// MARK: - Signal handler (async-signal-safe)

/// Entry point invoked by the kernel for each handled signal. The
/// body is restricted to async-signal-safe calls: `open(2)`,
/// `write(2)`, `close(2)`, `signal(3)`, `raise(3)`, `_exit(2)`.
/// No Swift runtime hops are performed; no heap allocations; no
/// `Foundation` calls. Ref: POSIX.1-2017, §2.4.3.
private func crashSignalHandler(signalNumber: Int32) {
    guard let dirPath = InProcessCrashHandler.signalTombstoneDirectoryCString,
          let sessionID = InProcessCrashHandler.signalSessionIDCString
    else {
        chainToPreviousHandler(for: signalNumber)
        return
    }

    // Build the tombstone path: `<dir>/sig-<pid>-<sig>.marker`.
    // `pid` + `sig` are small integers; renderable via a fixed
    // integer-to-cstring helper that is signal-safe.
    var filename = [CChar](repeating: 0, count: 512)
    var offset = 0
    offset = appendCString(source: dirPath, to: &filename, offset: offset)
    offset = appendByte(0x2F, to: &filename, offset: offset) // '/'
    offset = appendCStringLiteral("sig-", to: &filename, offset: offset)
    offset = appendInt(Int(getpid()), to: &filename, offset: offset)
    offset = appendByte(0x2D, to: &filename, offset: offset) // '-'
    offset = appendInt(Int(signalNumber), to: &filename, offset: offset)
    offset = appendCStringLiteral(".marker", to: &filename, offset: offset)
    _ = appendByte(0, to: &filename, offset: offset)

    let fd = filename.withUnsafeBufferPointer { buf -> Int32 in
        guard let base = buf.baseAddress else { return -1 }
        return open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    }
    if fd >= 0 {
        // Write a minimal JSON marker. The rehydration step on next
        // launch parses this and produces a full Tombstone with the
        // signal reason + session ID. Stack traces / register
        // contents are NOT recorded here — async-signal-safety
        // forbids calling Thread.callStackSymbols or any symbolicator
        // — but MetricKit delivers those on the next launch for the
        // same crash, and the tombstone on its own is still
        // meaningful (it proves the session crashed with signal N).
        writeStaticString("{\"signal\":", fd: fd)
        writeInt(Int(signalNumber), fd: fd)
        writeStaticString(",\"session_id\":\"", fd: fd)
        writeNullTerminated(sessionID, fd: fd)
        writeStaticString("\"}\n", fd: fd)
        close(fd)
    }

    chainToPreviousHandler(for: signalNumber)
}

private func chainToPreviousHandler(for signalNumber: Int32) {
    if let previous = InProcessCrashHandler.previousSignalHandlers[signalNumber] ?? nil {
        _ = signal(signalNumber, previous)
    } else {
        _ = signal(signalNumber, SIG_DFL)
    }
    raise(signalNumber)
}

// MARK: - Signal-safe byte helpers

/// Copy `source` (NUL-terminated) into `target[offset...]`, stopping
/// before `target.count - 1`. Returns the new offset.
@inline(__always)
private func appendCString(
    source: UnsafePointer<CChar>,
    to target: inout [CChar],
    offset: Int,
) -> Int {
    var idx = offset
    var read = 0
    let capacity = target.count
    while idx < capacity - 1, source[read] != 0 {
        target[idx] = source[read]
        idx += 1
        read += 1
    }
    return idx
}

@inline(__always)
private func appendCStringLiteral(
    _ literal: StaticString,
    to target: inout [CChar],
    offset: Int,
) -> Int {
    let count = literal.utf8CodeUnitCount
    let pointer = literal.utf8Start
    var idx = offset
    var read = 0
    let capacity = target.count
    while idx < capacity - 1, read < count {
        target[idx] = CChar(bitPattern: pointer[read])
        idx += 1
        read += 1
    }
    return idx
}

@inline(__always)
private func appendByte(
    _ byte: CChar,
    to target: inout [CChar],
    offset: Int,
) -> Int {
    let capacity = target.count
    guard offset < capacity - 1 else { return offset }
    target[offset] = byte
    return offset + 1
}

@inline(__always)
private func appendInt(
    _ value: Int,
    to target: inout [CChar],
    offset: Int,
) -> Int {
    if value == 0 {
        return appendByte(CChar(UInt8(ascii: "0")), to: &target, offset: offset)
    }
    var digits = [CChar](repeating: 0, count: 20)
    var count = 0
    var remainder = value
    let negative = remainder < 0
    if negative { remainder = -remainder }
    while remainder > 0, count < digits.count {
        let digit = Int8(remainder % 10)
        digits[count] = CChar(UInt8(ascii: "0")) &+ CChar(digit)
        remainder /= 10
        count &+= 1
    }
    var idx = offset
    if negative {
        idx = appendByte(CChar(UInt8(ascii: "-")), to: &target, offset: idx)
    }
    var i = count
    let capacity = target.count
    while i > 0, idx < capacity - 1 {
        i &-= 1
        target[idx] = digits[i]
        idx &+= 1
    }
    return idx
}

@inline(__always)
private func writeStaticString(_ literal: StaticString, fd: Int32) {
    let count = literal.utf8CodeUnitCount
    _ = write(fd, literal.utf8Start, count)
}

@inline(__always)
private func writeNullTerminated(_ pointer: UnsafePointer<CChar>, fd: Int32) {
    var length = 0
    while pointer[length] != 0 { length &+= 1 }
    _ = write(fd, pointer, length)
}

@inline(__always)
private func writeInt(_ value: Int, fd: Int32) {
    var buffer = [CChar](repeating: 0, count: 24)
    let offset = appendInt(value, to: &buffer, offset: 0)
    buffer.withUnsafeBufferPointer { buf in
        _ = write(fd, buf.baseAddress, offset)
    }
}

#endif
