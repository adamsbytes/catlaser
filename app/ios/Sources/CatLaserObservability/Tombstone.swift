import Foundation

/// Serialized record of a crash captured in-process by the signal
/// handler or the ``NSException`` handler. Written to a protected
/// file at crash time and picked up on the next launch for upload.
///
/// Captured fields are deliberately small and all stack-allocatable
/// so the crash handler (which runs in a signal context and must be
/// async-signal-safe) can assemble a tombstone without reaching for
/// heap APIs that are not signal-safe.
public struct Tombstone: Sendable, Codable, Equatable {
    public enum Reason: String, Sendable, Codable, Equatable {
        case uncaughtException = "uncaught_exception"
        case signalSIGABRT = "signal_sigabrt"
        case signalSIGSEGV = "signal_sigsegv"
        case signalSIGBUS = "signal_sigbus"
        case signalSIGILL = "signal_sigill"
        case signalSIGFPE = "signal_sigfpe"
        case signalSIGPIPE = "signal_sigpipe"
        case signalOther = "signal_other"
    }

    public let id: String
    public let reason: Reason
    /// UTC ISO-8601 timestamp of the crash.
    public let capturedAt: String
    /// Human-readable description (exception name + reason, or
    /// signal name). Bounded at 1 KB to avoid unbounded growth from a
    /// pathological exception reason string.
    public let summary: String
    /// Symbolicated call stack as a list of strings if one was
    /// captured. The signal-handler path records nil here because
    /// calling ``Thread.callStackSymbols`` from a signal handler is
    /// not async-signal-safe; the NSException path captures it.
    public let callStack: [String]?
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String

    public init(
        id: String,
        reason: Reason,
        capturedAt: String,
        summary: String,
        callStack: [String]?,
        appVersion: String,
        buildNumber: String,
        osVersion: String,
    ) {
        self.id = id
        self.reason = reason
        self.capturedAt = capturedAt
        self.summary = String(summary.prefix(1024))
        self.callStack = callStack
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
    }

    /// Map a POSIX signal number onto a ``Reason`` tag. Used by the
    /// signal handler — the handler is restricted to
    /// async-signal-safe APIs, but building a string from an int
    /// does not call back into the runtime.
    public static func reason(for signalNumber: Int32) -> Reason {
        switch signalNumber {
        case 6: .signalSIGABRT    // SIGABRT
        case 11: .signalSIGSEGV   // SIGSEGV
        case 10: .signalSIGBUS    // SIGBUS on Darwin / Linux
        case 4: .signalSIGILL     // SIGILL
        case 8: .signalSIGFPE     // SIGFPE
        case 13: .signalSIGPIPE   // SIGPIPE
        default: .signalOther
        }
    }
}

/// Protected-class file store for tombstones.
///
/// Tombstones are written under
/// `~/Library/Caches/Observability/Tombstones/` with the iOS file
/// protection class ``FileProtectionType.completeUntilFirstUserAuthentication``.
/// That means the file is encrypted at rest but accessible once the
/// user has unlocked the device at least once since boot — which is
/// the invariant a crash handler needs (the crash happens while the
/// app is foregrounded, i.e. already past first-unlock).
///
/// The store is deliberately restricted to:
///
/// - Creation on a fresh launch (composition startup).
/// - Writing a single tombstone via ``write(tombstone:)`` from the
///   signal handler. The signal-safe caller must use a pre-allocated
///   path + use `open(2)` + `write(2)` directly; this store's
///   ``writeFromNormalContext`` helper is the non-signal-safe path.
/// - Reading + deleting on the next launch to drain any pending
///   tombstones.
public struct TombstoneStore: Sendable {
    /// Directory that holds pending tombstones.
    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Ensure the tombstone directory exists with the correct
    /// protection class. Idempotent — safe to call on every launch.
    public func prepare() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil,
                )
            } catch {
                throw ObservabilityError.queueIOFailed(
                    "create tombstone directory: \(error.localizedDescription)",
                )
            }
        }
        applyProtectionClass(to: directory)
    }

    /// Write a tombstone from a normal execution context (e.g. the
    /// ``NSException`` handler, which runs on the same stack as
    /// normal Swift code). The signal-handler path uses a separate
    /// pre-allocated path and writes bytes via ``write(2)``.
    public func writeFromNormalContext(_ tombstone: Tombstone) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(tombstone)
        } catch {
            throw ObservabilityError.encodingFailed("tombstone: \(error)")
        }
        let url = directory.appendingPathComponent("\(tombstone.id).json")
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ObservabilityError.queueIOFailed(
                "write tombstone: \(error.localizedDescription)",
            )
        }
        applyProtectionClass(to: url)
    }

    /// Enumerate all pending tombstones.
    public func pending() throws -> [Tombstone] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
            )
        } catch {
            throw ObservabilityError.queueIOFailed(
                "list tombstones: \(error.localizedDescription)",
            )
        }
        let decoder = JSONDecoder()
        var tombstones: [Tombstone] = []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(Tombstone.self, from: data)
            else {
                continue
            }
            tombstones.append(decoded)
        }
        return tombstones
    }

    /// Delete a processed tombstone. Called after a successful
    /// upload.
    public func delete(id: String) throws {
        let url = directory.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ObservabilityError.queueIOFailed(
                "delete tombstone: \(error.localizedDescription)",
            )
        }
    }

    /// Delete all tombstones — used on consent withdrawal.
    public func purge() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
        )) ?? []
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    private func applyProtectionClass(to url: URL) {
        #if canImport(UIKit) && !os(watchOS)
        // The `completeUntilFirstUserAuthentication` class is
        // specifically designed for crash reporters — the file is
        // encrypted at rest but becomes available once the user has
        // unlocked the device at least once since boot. Our crash
        // handler never runs before first-unlock (the crash happens
        // with the app in the foreground), so this class is strictly
        // preferable to `complete` (which would forbid writes while
        // the device is locked — not our case, but the principle is
        // to use the strictest class that supports the access
        // pattern).
        try? (url as NSURL).setResourceValue(
            FileProtectionType.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey,
        )
        #endif
    }
}
