import Foundation

/// Public facade for the observability pipeline.
///
/// A single ``Observability`` instance is constructed at app launch
/// (from ``AppComposition.production``), passed a fully-wired
/// ``ObservabilityConfig``, a consent store, a transport, and a
/// breadcrumb ring. The facade owns:
///
/// - The breadcrumb ring (bounded in-memory + persisted snapshot)
/// - The telemetry queue (file-backed, crash-safe)
/// - The tombstone store (pending crash payloads)
/// - The MetricKit bridge (Apple-signed diagnostic payloads)
/// - The consent gate (every upload respects the current state)
///
/// Every caller-facing entry point is an actor method; the actor's
/// queue serialises concurrent emits and drains so there is no
/// contention on a lock. Recording a breadcrumb or a telemetry
/// event MUST never fail the caller — the actor handles encoding
/// failures internally and converts them into in-line breadcrumbs
/// of ``Breadcrumb.Kind/error`` so a misbehaving schema is visible
/// in the next crash upload.
public actor Observability: BreadcrumbRecorder {
    /// Session ID regenerated at every ``Observability`` construction.
    /// Surfaced publicly so the crash handler can reference it from a
    /// signal context.
    public nonisolated let sessionID: String

    private let config: ObservabilityConfig
    private let consent: ConsentStore
    private let transport: any ObservabilityTransport
    private let queue: TelemetryQueue
    private let ring: BreadcrumbRing
    private let tombstones: TombstoneStore
    private let context: ObservabilityContext
    private let processStart: Date

    private var drainInFlight: Bool = false

    public init(
        config: ObservabilityConfig,
        consent: ConsentStore,
        transport: any ObservabilityTransport,
        sessionID: String = UUID().uuidString,
    ) {
        self.config = config
        self.consent = consent
        self.transport = transport
        self.sessionID = sessionID
        self.ring = BreadcrumbRing(
            capacity: 50,
            persistenceURL: config.breadcrumbsURL,
        )
        self.queue = TelemetryQueue(
            configuration: TelemetryQueue.Configuration(queueURL: config.queueURL),
        )
        self.tombstones = TombstoneStore(directory: config.tombstoneDirectory)
        self.context = DeviceContextBuilder.current(
            sessionID: sessionID,
            config: config,
        )
        self.processStart = Date()
    }

    // MARK: - Recording

    /// Record a breadcrumb on the in-memory ring + persistent
    /// snapshot. Always runs regardless of consent — breadcrumbs
    /// never leave the device on their own, and the ring's
    /// consent-guarded surface is "attach to a crash upload".
    public nonisolated func record(_ breadcrumb: Breadcrumb) {
        Task { [ring] in
            await ring.record(breadcrumb)
        }
    }

    /// Record a strongly-typed telemetry event. Respects consent:
    /// if the user has not opted in to telemetry the event is
    /// dropped on the floor (and a matching breadcrumb is written
    /// so a later crash upload can still see "tried to record
    /// event X but telemetry is off").
    public func record(event: TelemetryEvent) async {
        record(
            .note,
            event.wireName,
            attributes: event.wireAttributes,
        )

        let state = await consent.load()
        guard state.telemetryEnabled else { return }

        let envelope = envelope(for: event)
        do {
            try await queue.enqueue(envelope)
        } catch {
            record(
                .error,
                "telemetry.enqueue_failed",
                attributes: ["reason": String(describing: error)],
            )
        }
    }

    // MARK: - Draining

    /// Drain any queued events + pending tombstones and upload them.
    /// Callers are expected to call this:
    ///
    /// - Once on startup, once any required background time is
    ///   acquired.
    /// - On ``UIApplication/willResignActive`` / ``didEnterBackground``
    ///   notifications (best-effort flush before suspension).
    /// - On an explicit "retry now" user tap if a settings screen
    ///   exposes one.
    ///
    /// The drain is idempotent and cooperative: a second concurrent
    /// call while the first is in flight no-ops cleanly.
    public func drain() async {
        guard !drainInFlight else { return }
        drainInFlight = true
        defer { drainInFlight = false }

        let state = await consent.load()
        guard state.crashReportingEnabled || state.telemetryEnabled else { return }

        if state.crashReportingEnabled {
            await drainTombstones()
        }
        if state.telemetryEnabled {
            await drainTelemetryQueue()
        }
    }

    /// Receive a batch of crash payloads from the ``MetricKitBridge``
    /// and enqueue them for upload.
    public func ingestCrashPayloads(_ payloads: [CrashPayload]) async {
        let state = await consent.load()
        guard state.crashReportingEnabled else { return }
        let breadcrumbs = await ring.snapshot()
        for var payload in payloads {
            // Attach the breadcrumb snapshot that was live when the
            // payload arrived. MetricKit delivers on next launch so
            // the attached breadcrumbs are technically from the new
            // session — the server is expected to treat the
            // `session_id` on the envelope as the crashed session
            // (MetricKit's own payload carries the real pid and
            // bundle version it fired against).
            payload = CrashPayload(
                id: payload.id,
                source: payload.source,
                payload: payload.payload,
                breadcrumbs: breadcrumbs,
            )
            await uploadCrashPayload(payload)
        }
    }

    // MARK: - Lifecycle helpers

    /// Wipe all local observability state. Called on sign-out so a
    /// second user on the same device does not inherit the
    /// previous user's breadcrumb trail or pending telemetry.
    public func purgeLocalState() async {
        await ring.purge()
        try? await queue.purge()
        try? tombstones.purge()
    }

    // MARK: - Internals

    private func envelope(for event: TelemetryEvent) -> EventEnvelope {
        let monotonic = UInt64(Date().timeIntervalSince(processStart) * 1_000_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wallTime = formatter.string(from: Date())
        return EventEnvelope(
            id: UUID().uuidString,
            name: event.wireName,
            attributes: event.wireAttributes,
            monotonicNS: monotonic,
            wallTimeUTC: wallTime,
        )
    }

    private func drainTelemetryQueue() async {
        let events: [EventEnvelope]
        do {
            events = try await queue.drainBatch()
        } catch {
            record(
                .error,
                "telemetry.drain_failed",
                attributes: ["reason": String(describing: error)],
            )
            return
        }
        guard !events.isEmpty else { return }
        let batch = UploadBatch(context: context, events: events, crash: nil)
        do {
            try await transport.upload(batch)
            try await queue.acknowledge(upTo: events.count)
        } catch ObservabilityError.uploadRejected(let status) {
            // Server rejected the batch — discard so we don't loop
            // forever on a poison message.
            try? await queue.acknowledge(upTo: events.count)
            record(
                .error,
                "telemetry.upload_rejected",
                attributes: ["status": String(status)],
            )
        } catch {
            // Transient error — leave the batch in place.
            record(
                .error,
                "telemetry.upload_transient",
                attributes: ["reason": String(describing: error)],
            )
        }
    }

    private func drainTombstones() async {
        let pending: [Tombstone]
        do {
            pending = try tombstones.pending()
        } catch {
            record(
                .error,
                "tombstone.list_failed",
                attributes: ["reason": String(describing: error)],
            )
            return
        }
        for tombstone in pending {
            let encoded: String
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(tombstone)
                encoded = String(data: data, encoding: .utf8) ?? ""
            } catch {
                try? tombstones.delete(id: tombstone.id)
                continue
            }
            let payload = CrashPayload(
                id: tombstone.id,
                source: .tombstone,
                payload: encoded,
                breadcrumbs: await ring.snapshot(),
            )
            await uploadCrashPayload(payload)
            try? tombstones.delete(id: tombstone.id)
        }
    }

    private func uploadCrashPayload(_ payload: CrashPayload) async {
        let batch = UploadBatch(context: context, events: [], crash: payload)
        do {
            try await transport.upload(batch)
            // Record a matching telemetry event so the crash delivery
            // shows up in the event stream alongside the raw payload.
            await record(
                event: .crashReportDelivered(
                    source: payload.source == .metricKit ? .metricKit : .tombstone,
                ),
            )
        } catch {
            record(
                .error,
                "crash.upload_failed",
                attributes: [
                    "reason": String(describing: error),
                    "source": payload.source.rawValue,
                ],
            )
        }
    }
}
