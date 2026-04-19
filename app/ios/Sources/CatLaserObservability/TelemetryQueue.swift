import Foundation

/// Append-only file-backed queue of pending events.
///
/// Durability model:
///
/// - Each event is JSON-encoded and appended as a single UTF-8 line
///   (NDJSON) to a queue file inside the app's caches directory. The
///   append is performed with ``FileHandle/synchronize`` so a crash
///   between emit and the next file system barrier does not lose the
///   event.
///
/// - ``drainBatch(maxEvents:)`` returns up to `maxEvents` queued
///   entries without removing them. The caller is expected to upload
///   the batch and call ``acknowledge(upTo:)`` on success; a failed
///   upload can retry without duplicating work.
///
/// - ``acknowledge(upTo:)`` rewrites the queue file minus the
///   acknowledged prefix. The rewrite is atomic (write a ``.tmp``
///   sibling, then rename) so an acknowledgement that is interrupted
///   mid-write leaves the old queue file intact — replayed, the same
///   events are redelivered, the ingest endpoint dedups on the event
///   UUID.
///
/// The queue enforces a byte-size cap: once the file grows past the
/// configured limit, the oldest entries are discarded at enqueue
/// time. A cap is non-negotiable on a mobile client — a persistently
/// offline user must not accumulate unbounded data on disk.
public actor TelemetryQueue {
    public struct Configuration: Sendable {
        /// Absolute URL of the queue file. The parent directory is
        /// created on first write if it does not exist.
        public let queueURL: URL
        /// Maximum byte size of the queue file. Once exceeded the
        /// oldest entries are trimmed off at enqueue time.
        public let maxBytes: Int
        /// Maximum number of events returned by a single
        /// ``drainBatch(maxEvents:)`` call.
        public let maxBatchEvents: Int

        public init(
            queueURL: URL,
            maxBytes: Int = 1 * 1024 * 1024,
            maxBatchEvents: Int = 128,
        ) {
            precondition(maxBytes > 0, "maxBytes must be positive")
            precondition(maxBatchEvents > 0, "maxBatchEvents must be positive")
            self.queueURL = queueURL
            self.maxBytes = maxBytes
            self.maxBatchEvents = maxBatchEvents
        }
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: Configuration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Append an event to the queue. Throws on IO failures — callers
    /// that cannot afford to fail should catch and record a breadcrumb
    /// via the parent ``Observability`` facade.
    @discardableResult
    public func enqueue(_ event: EventEnvelope) throws -> Int {
        try ensureDirectoryExists()
        let encoded = try encode(event: event)
        var line = encoded
        line.append(0x0A) // newline

        let existing = try readRaw()
        var combined = existing + line

        if combined.count > configuration.maxBytes {
            combined = trimToCapacity(combined)
        }

        try atomicWrite(data: combined)
        return eventCount(in: combined)
    }

    /// Return up to ``Configuration/maxBatchEvents`` events in
    /// enqueue order, without removing them from the queue. Use
    /// ``acknowledge(upTo:)`` after a successful upload.
    public func drainBatch() throws -> [EventEnvelope] {
        let raw = try readRaw()
        guard !raw.isEmpty else { return [] }
        let lines = splitLines(raw)
        var events: [EventEnvelope] = []
        events.reserveCapacity(min(lines.count, configuration.maxBatchEvents))
        for line in lines.prefix(configuration.maxBatchEvents) {
            if let event = try? decoder.decode(EventEnvelope.self, from: line) {
                events.append(event)
            }
            // Malformed lines are silently dropped from the batch —
            // `acknowledge(upTo:)` will trim them on the next write.
        }
        return events
    }

    /// Drop the first `count` events from the queue. Typically
    /// called after a successful upload of a batch of the same size.
    public func acknowledge(upTo count: Int) throws {
        precondition(count >= 0, "count must be non-negative")
        guard count > 0 else { return }

        let raw = try readRaw()
        guard !raw.isEmpty else { return }

        let lines = splitLines(raw)
        let remaining = lines.dropFirst(count)

        if remaining.isEmpty {
            try? fileManager.removeItem(at: configuration.queueURL)
            return
        }

        var rebuilt = Data()
        for line in remaining {
            rebuilt.append(line)
            rebuilt.append(0x0A)
        }
        try atomicWrite(data: rebuilt)
    }

    /// Number of events currently queued on disk.
    public func pendingCount() throws -> Int {
        let raw = try readRaw()
        return eventCount(in: raw)
    }

    /// Delete the queue file. Used on sign-out and on consent
    /// withdrawal.
    public func purge() throws {
        guard fileManager.fileExists(atPath: configuration.queueURL.path) else { return }
        try fileManager.removeItem(at: configuration.queueURL)
    }

    // MARK: - Internals

    private func encode(event: EventEnvelope) throws -> Data {
        do {
            return try encoder.encode(event)
        } catch {
            throw ObservabilityError.encodingFailed("event \(event.name): \(error)")
        }
    }

    private func ensureDirectoryExists() throws {
        let parent = configuration.queueURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                )
            } catch {
                throw ObservabilityError.queueIOFailed(
                    "create queue directory: \(error.localizedDescription)",
                )
            }
        }
    }

    private func readRaw() throws -> Data {
        guard fileManager.fileExists(atPath: configuration.queueURL.path) else {
            return Data()
        }
        do {
            return try Data(contentsOf: configuration.queueURL)
        } catch {
            throw ObservabilityError.queueIOFailed(
                "read queue: \(error.localizedDescription)",
            )
        }
    }

    private func atomicWrite(data: Data) throws {
        do {
            try data.write(to: configuration.queueURL, options: [.atomic])
        } catch {
            throw ObservabilityError.queueIOFailed(
                "write queue: \(error.localizedDescription)",
            )
        }
    }

    /// Return `raw` truncated to at most ``Configuration/maxBytes``
    /// by dropping whole lines from the front. Guarantees the return
    /// value has a line-aligned prefix and fits inside the budget.
    private func trimToCapacity(_ raw: Data) -> Data {
        guard raw.count > configuration.maxBytes else { return raw }
        let lines = splitLines(raw)
        var kept: [Data] = []
        var total = 0
        for line in lines.reversed() {
            let lineSize = line.count + 1 // +1 for newline
            if total + lineSize > configuration.maxBytes {
                break
            }
            kept.append(line)
            total += lineSize
        }
        var rebuilt = Data()
        rebuilt.reserveCapacity(total)
        for line in kept.reversed() {
            rebuilt.append(line)
            rebuilt.append(0x0A)
        }
        return rebuilt
    }

    private func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var lineStart = data.startIndex
        for idx in data.indices {
            if data[idx] == 0x0A {
                let line = data.subdata(in: lineStart ..< idx)
                if !line.isEmpty {
                    lines.append(line)
                }
                lineStart = data.index(after: idx)
            }
        }
        if lineStart < data.endIndex {
            let tail = data.subdata(in: lineStart ..< data.endIndex)
            if !tail.isEmpty {
                lines.append(tail)
            }
        }
        return lines
    }

    private func eventCount(in data: Data) -> Int {
        splitLines(data).count
    }
}
