import Foundation

/// Fixed-capacity ring buffer of ``Breadcrumb`` entries, backed by an
/// actor so concurrent emitters (the auth coordinator, the
/// connection supervisor, and each screen's view model) can record
/// in parallel without contention on a lock.
///
/// ## Capacity
///
/// The capacity is fixed at construction — typically 50. When the
/// ring is full the oldest entry is overwritten. This cap is
/// load-bearing: if a badly-behaved view model started emitting a
/// breadcrumb per frame, an unbounded buffer would eventually
/// exhaust the process; the fixed-size ring keeps the memory
/// envelope constant at O(capacity × bytes-per-breadcrumb).
///
/// ## Persistence
///
/// Every write is mirrored to an on-disk snapshot so a crash
/// handler running at signal-time (see ``TombstoneStore``) can
/// attach the most recent breadcrumbs to the persisted tombstone
/// even though the in-memory ring is gone. The on-disk snapshot is
/// an atomically replaced JSON array; small enough (≤ 50 × 1 KB =
/// 50 KB worst case) that a full-file rewrite per breadcrumb is
/// well inside the steady-state noise floor.
///
/// On platforms without Darwin (Linux SPM) the persistence path is a
/// best-effort plain file; on iOS the ``ObservabilityStorage`` helper
/// installs the `completeUntilFirstUserAuthentication` protection
/// class (see `TombstoneStore`), matching what Apple does for crash
/// reporters.
public actor BreadcrumbRing {
    private var storage: [Breadcrumb]
    private var head: Int = 0
    private var count: Int = 0
    public let capacity: Int

    /// URL of the persistent snapshot file. Writes are best-effort;
    /// a failed write does not throw because dropping persistence is
    /// strictly preferable to losing the in-memory breadcrumb that
    /// triggered the write.
    private let persistenceURL: URL?
    private let fileManager: FileManager

    public init(
        capacity: Int = 50,
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
    ) {
        precondition(capacity > 0, "BreadcrumbRing capacity must be positive")
        self.capacity = capacity
        self.storage = []
        self.storage.reserveCapacity(capacity)
        self.persistenceURL = persistenceURL
        self.fileManager = fileManager
    }

    /// Record a breadcrumb into the ring and flush the on-disk
    /// snapshot. The flush is best-effort; persistence failures do
    /// not surface to the caller because breadcrumb recording is a
    /// fire-and-forget operation that must never fail its caller.
    public func record(_ crumb: Breadcrumb) {
        if count < capacity {
            storage.append(crumb)
            count += 1
        } else {
            storage[head] = crumb
            head = (head + 1) % capacity
        }
        writeSnapshot()
    }

    /// Snapshot of the current breadcrumbs in chronological order
    /// (oldest first).
    public func snapshot() -> [Breadcrumb] {
        guard count > 0 else { return [] }
        if count < capacity {
            return storage
        }
        var ordered: [Breadcrumb] = []
        ordered.reserveCapacity(capacity)
        for offset in 0 ..< capacity {
            let idx = (head + offset) % capacity
            ordered.append(storage[idx])
        }
        return ordered
    }

    /// Erase all breadcrumbs and delete the persistent snapshot.
    /// Used on sign-out so a new user on the same device cannot read
    /// the previous user's audit trail.
    public func purge() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
        if let url = persistenceURL {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Persistence

    private func writeSnapshot() {
        guard let url = persistenceURL else { return }
        let ordered = snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Deterministic key order — a test that decodes the snapshot
        // asserts structural equality by comparing raw bytes.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ordered) else { return }
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try? fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
            )
        }
        // Atomic replace so an observer reading the file mid-write
        // never sees a half-written JSON document.
        try? data.write(to: url, options: [.atomic])
    }

    /// Restore a ring from a previously-written snapshot. Used on
    /// launch to rehydrate the last session's trailing breadcrumbs so
    /// a next-launch crash report can be annotated with "what was
    /// happening before the crash".
    public static func restoreFromSnapshot(
        at url: URL,
        fileManager: FileManager = .default,
    ) -> [Breadcrumb] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Breadcrumb].self, from: data)) ?? []
    }
}
