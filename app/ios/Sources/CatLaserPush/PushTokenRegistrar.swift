import CatLaserAuth
import CatLaserDevice
import CatLaserProto
import Foundation

/// Actor that owns the push-token lifecycle on the device channel.
///
/// Responsibilities:
///
/// 1. Register the current APNs token with the paired device via
///    ``RegisterPushTokenRequest`` whenever the token changes or the
///    device-channel ``DeviceClient`` is swapped (e.g. the supervisor
///    reconnected after a drop).
/// 2. Dedupe: a repeated register call with the same
///    ``(client, token)`` tuple is a no-op. The device's
///    ``register_push_token`` CRUD is idempotent (an UPSERT), but
///    the attestation-signed round-trip is not free and a tight
///    reconnect loop would otherwise re-register on every heartbeat.
/// 3. Unregister on sign-out: ``SessionLifecycleObserver`` conformance
///    fires the wire call and wipes the cache. A failure to reach the
///    device mid-sign-out does not block sign-out — the row will
///    be cleaned by the server-side APNs feedback service the next
///    time the token is rejected.
/// 4. Hold the subscriber handoff: ``PushViewModel`` observes
///    ``latestOutcomeStream`` to drive screen state transitions.
///
/// ## Observer semantics
///
/// ``sessionDidSignOut()`` unregisters AND wipes the local cache so
/// the next sign-in re-issues the register. ``sessionDidExpire()``
/// uses the protocol's default no-op: a 401 on the coordination
/// server means "the user needs to re-authenticate with us," not
/// "the user no longer wants push notifications." Wiping the token
/// there would force a re-register round-trip on every expiry-and-
/// restore cycle for zero benefit.
///
/// ## Reentrancy
///
/// Actor isolation serialises every wire call; the "currently
/// registering" flag is held in-actor, so a caller that fires
/// `setClient` then `setToken` back-to-back sees the two register
/// attempts run sequentially, not concurrently. Each call consults
/// the cache; only the second one reaches the wire if both carry a
/// fresh `(client, token)` pair.
public actor PushTokenRegistrar: SessionLifecycleObserver {
    /// Outbound state stream consumed by ``PushViewModel`` to
    /// transition its registration state. A single, unbounded stream
    /// is load-bearing: the VM is the only consumer, and a lost
    /// outcome between the register and its reply would strand the VM
    /// in ``registering`` forever.
    public nonisolated var outcomes: AsyncStream<Outcome> { outcomeStream }

    /// Outcome emitted after each wire attempt (or each attempt
    /// refused before reaching the wire).
    public enum Outcome: Sendable, Equatable {
        /// Successfully registered the supplied token with the
        /// supplied client identity. The client identity is opaque
        /// to the consumer — it exists so a late-arriving outcome
        /// for a stale client is easy to ignore.
        case registered(token: PushToken)
        /// Successfully unregistered. No token is reported because
        /// the caller doesn't care which token was just revoked —
        /// only that none is active.
        case unregistered
        /// A register attempt failed; the token was NOT cached.
        case failed(PushError)
    }

    // MARK: - Stored

    /// Currently-targeted device client. Nil before ``setClient``
    /// first fires (the supervisor is still connecting). Identity
    /// comparison (`===`) is used to detect client swaps — a fresh
    /// supervisor reconnect produces a NEW `DeviceClient` instance,
    /// even at the same endpoint, so the identity check fires a
    /// fresh registration.
    private var currentClient: DeviceClient?

    /// Last APNs token the app observed. Cached so a repeated
    /// ``setToken`` with the same value is a no-op.
    private var currentToken: PushToken?

    /// Identity of the client the cached token was registered against.
    /// Nil until a register succeeds. Compared by identity (`===`)
    /// against ``currentClient`` — a mismatch means the supervisor
    /// rebuilt the client and we must re-register regardless of
    /// whether the token changed.
    private var registeredClient: DeviceClient?

    /// Token currently registered on ``registeredClient``, if any.
    /// Separate from ``currentToken`` because the cached token and the
    /// registered token diverge for the brief window between a fresh
    /// APNs delivery and the register reply.
    private var registeredToken: PushToken?

    private let outcomeStream: AsyncStream<Outcome>
    private let outcomeContinuation: AsyncStream<Outcome>.Continuation

    public init() {
        var captured: AsyncStream<Outcome>.Continuation!
        self.outcomeStream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.outcomeContinuation = captured
    }

    // MARK: - Public API

    /// Swap the device client the registrar talks to.
    ///
    /// Called by the hosting composition whenever the
    /// ``ConnectionManager`` surfaces a fresh ``.connected(client)``
    /// state. Passing ``nil`` retains the cached token (the user did
    /// not unpair; we just lost the TCP channel) but drops the
    /// registered-against-client reference so the next connect
    /// re-registers.
    ///
    /// Idempotent at the identity level — setting the same client
    /// twice is a no-op.
    public func setClient(_ client: DeviceClient?) async {
        // Detect an actual change by reference. `DeviceClient` is an
        // actor, not a `Sendable` value type; identity (`===`) is the
        // right comparison.
        switch (currentClient, client) {
        case (nil, nil):
            return
        case let (lhs?, rhs?) where lhs === rhs:
            return
        default:
            break
        }
        currentClient = client
        if client == nil {
            // Disconnect: keep the cached APNs token (the user did
            // not change their mind about push), but drop the
            // registered-against-client reference so the next client
            // fires a fresh register.
            registeredClient = nil
            registeredToken = nil
            return
        }
        // New client — re-register the cached token if we have one.
        if currentToken != nil {
            await attemptRegister()
        }
    }

    /// Hand the registrar a freshly-observed APNs token.
    ///
    /// Called by the push-authorization glue on every
    /// ``application(_:didRegisterForRemoteNotificationsWithDeviceToken:)``
    /// delivery. Idempotent at the token-value level — the same token
    /// is dropped on the floor. A changed token (APNs re-minted on
    /// install / restore) triggers a fresh register against whatever
    /// client is currently in hand.
    public func setToken(_ token: PushToken) async {
        if currentToken == token, registeredClient != nil, registeredToken == token {
            // Exactly the same token, already acknowledged on the
            // current client. Drop on the floor.
            return
        }
        currentToken = token
        await attemptRegister()
    }

    /// Force a register attempt against the current state. Useful for
    /// the VM's "retry" button on a failed state.
    public func retry() async {
        await attemptRegister()
    }

    /// Explicit unregister. Clears both local caches regardless of
    /// the wire outcome — a failure to reach the device side does not
    /// strand the caller in "I'm signed out but the registrar still
    /// thinks it's registered" land.
    ///
    /// Public so the composition or tests can force an unregister
    /// without going through the ``SessionLifecycleObserver`` hook.
    public func unregister() async {
        guard let client = currentClient, let token = registeredToken else {
            // Nothing to tell the device, but still wipe local state
            // so a subsequent signOut observer call doesn't find a
            // stale row.
            currentToken = nil
            registeredClient = nil
            registeredToken = nil
            outcomeContinuation.yield(.unregistered)
            return
        }
        var request = Catlaser_App_V1_AppRequest()
        var unregister = Catlaser_App_V1_UnregisterPushTokenRequest()
        unregister.token = token.hex
        request.unregisterPushToken = unregister
        // Fire-and-forget on the outcome: we wipe local state either
        // way. A transport failure here is diagnostic only — the
        // server-side row will be cleaned on the next push attempt
        // that fails with HTTP 404/410 (see
        // ``catlaser_brain.network.push.PushNotifier._send_to_all``).
        _ = try? await client.request(request)
        currentToken = nil
        registeredClient = nil
        registeredToken = nil
        outcomeContinuation.yield(.unregistered)
    }

    // MARK: - SessionLifecycleObserver

    /// Sign-out: unregister and wipe every local cache. Swallows
    /// transport failure — observers must not throw, and the server
    /// row gets cleaned by the APNs feedback service anyway.
    public func sessionDidSignOut() async {
        await unregister()
    }

    // `sessionDidExpire` uses the protocol default (no-op). Expiry
    // means "re-auth needed", not "user gave up on push"; wiping the
    // token on every 401 would churn registrations for zero benefit.

    // MARK: - Internal: register round-trip

    private func attemptRegister() async {
        guard let client = currentClient else { return }
        guard let token = currentToken else { return }

        if registeredClient === client, registeredToken == token {
            // Nothing to do.
            return
        }
        var request = Catlaser_App_V1_AppRequest()
        var register = Catlaser_App_V1_RegisterPushTokenRequest()
        register.token = token.hex
        register.platform = .apns
        request.registerPushToken = register
        do {
            let event = try await client.request(request)
            switch event.event {
            case .pushTokenAck:
                // Pin the cache to BOTH the client identity and the
                // token so a later call that swaps either reference
                // fires a fresh register.
                registeredClient = client
                registeredToken = token
                outcomeContinuation.yield(.registered(token: token))
            case let .error(remote):
                let mapped = PushError.deviceError(code: remote.code, message: remote.message)
                outcomeContinuation.yield(.failed(mapped))
            default:
                outcomeContinuation.yield(
                    .failed(.wrongEventKind(
                        expected: "push_token_ack",
                        got: event.event?.shortName ?? "unspecified",
                    )),
                )
            }
        } catch let error as DeviceClientError {
            outcomeContinuation.yield(.failed(.from(error)))
        } catch {
            outcomeContinuation.yield(.failed(.internalFailure(error.localizedDescription)))
        }
    }
}

// MARK: - Oneof shorthand

private extension Catlaser_App_V1_DeviceEvent.OneOf_Event {
    /// Stable short names for ``wrongEventKind`` diagnostics. Kept
    /// on this file (not shared with history / schedule) so a
    /// codegen rename is caught independently on each surface.
    var shortName: String {
        switch self {
        case .statusUpdate: "status_update"
        case .catProfileList: "cat_profile_list"
        case .playHistory: "play_history"
        case .streamOffer: "stream_offer"
        case .sessionSummary: "session_summary"
        case .newCatDetected: "new_cat_detected"
        case .hopperEmpty: "hopper_empty"
        case .diagnosticResult: "diagnostic_result"
        case .error: "error"
        case .schedule: "schedule"
        case .pushTokenAck: "push_token_ack"
        case .authResponse: "auth_response"
        }
    }
}
