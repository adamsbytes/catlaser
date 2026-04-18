import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client that attaches the three headers every authenticated request
/// to the coordination server requires, and refuses to send the request at
/// all if any of them cannot be produced:
///
/// 1. `Authorization: Bearer <token>` — loaded from the caller-supplied
///    `BearerTokenStore`. Missing session → `AuthError.missingBearerToken`
///    and no wire call. An empty stored bearer is treated identically to
///    a missing session: the ACL-protected keychain read returned a row,
///    but the row is structurally unusable and would produce a 401 on
///    the server anyway; failing locally surfaces the bug faster and
///    does not leak a malformed header.
///
/// 2. `x-device-attestation: <base64 v4 payload>` — built fresh on every
///    call via `DeviceAttestationProviding.currentAttestationHeader(binding:)`
///    with `binding = .api(timestamp: <now_seconds>)`. The timestamp is
///    verified against the same plausible-clock band as
///    `AuthCoordinator` (2020-01-01 .. 2100-01-01) before the header is
///    signed; a device with a broken clock cannot emit a signature that
///    the server's ±60s skew check would accept, so the wrapper refuses
///    locally rather than burning a Secure-Enclave signing operation.
///    ADR-006 pins this as the single gate between a captured bearer and
///    a successful protected-route call: a leaked bearer without the
///    non-extractable SE private key cannot produce a fresh `api:`
///    signature.
///
/// 3. `Idempotency-Key: <rfc-4122 uuid>` — attached only on mutating
///    methods (POST, PUT, PATCH, DELETE; case-insensitive). Closes the
///    residual write-replay window inside the 60s attestation skew: a
///    captured `(bearer, attestation)` pair re-submitted against the
///    same route produces a cache hit on `(session_id, key)` server-side
///    and the mutation does NOT re-execute. If the caller pre-set the
///    header (e.g. to re-use a key across a client-side retry), the
///    wrapper validates it against the same canonical UUID regex the
///    server enforces and preserves it byte-for-byte; otherwise it
///    auto-generates a fresh lowercase UUID. Read methods (GET, HEAD,
///    OPTIONS, and any non-standard verb) never receive the header,
///    matching the server contract that rejects `Idempotency-Key` only
///    on mutating routes.
///
/// The wrapper OWNS these three header names: any pre-existing
/// `Authorization` or `x-device-attestation` on the request is
/// overwritten. That is load-bearing. A call site that constructs a
/// `URLRequest` with its own Authorization and passes it through
/// `SignedHTTPClient` would otherwise have two Authorization headers on
/// the wire (URLRequest's `setValue` semantics replace, but a refactor
/// could reach for `addValue` — the invariant that the wrapper wins is
/// enforced here once and asserted by tests). For `Idempotency-Key` the
/// semantics are opposite: preserve caller input (with format validation)
/// so retry-with-dedup is an explicit caller decision.
///
/// `SignedHTTPClient` itself conforms to `HTTPClient` so it composes,
/// but the composition boundary is intentionally narrow: the ONLY
/// public initializer takes a concrete `PinnedHTTPClient`, which can
/// itself only be constructed from a `TLSPinning` set (see
/// `PinnedHTTPClient`). A future refactor that wired an unpinned
/// `URLSession` into the protected call path would therefore fail to
/// compile against this file's public surface — pinning becomes a
/// type-system invariant rather than a convention.
///
/// Tests (`CatLaserAuthTests`, `CatLaserPairingTests`) reach the
/// package-private `init(underlying: any HTTPClient, ...)` through
/// `@testable import CatLaserAuth` to swap in a `MockHTTPClient` for
/// full-stack signing assertions. That seam is invisible to the
/// product target — `CatLaserApp` / `CatLaserPairing` build without
/// `@testable` and therefore cannot reach it.
public struct SignedHTTPClient: HTTPClient {
    public static let authorizationHeaderName = "Authorization"
    public static let idempotencyHeaderName = "Idempotency-Key"

    /// HTTP methods that must carry an `Idempotency-Key`. Matches the
    /// server-side `withIdempotentAttestedSession` wrapper's contract
    /// (ADR-006 / `server/src/lib/idempotency.ts`): POST/PUT/PATCH/DELETE
    /// are the mutating verbs; everything else is read and the server
    /// rejects a stray key with 400. Comparison is case-insensitive so a
    /// caller that built a `URLRequest` with `httpMethod = "post"`
    /// (lowercase — Foundation does NOT normalize this) still hits the
    /// mutating branch.
    public static let mutatingMethods: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]

    /// Canonical RFC 4122 UUID form the server accepts for
    /// `Idempotency-Key`. Mirrors `UUID_PATTERN` in
    /// `server/src/lib/idempotency.ts`: 8-4-4-4-12 hex, case-insensitive.
    /// Kept as a single source of truth so the app and the server's
    /// regex cannot drift.
    public static let idempotencyKeyPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#

    /// Callback fired once per observed HTTP 401 on a protected call.
    /// Marked `async` because the production binding routes it into
    /// `AuthCoordinator.handleSessionExpired()` — an actor method that
    /// invalidates the in-memory bearer cache and notifies lifecycle
    /// observers. The return of `send(_:)` is NOT awaited on the
    /// callback; the 401 response is propagated to the caller exactly
    /// as received, and the callback runs concurrently so it never
    /// stalls the request/response path. Callers that depend on the
    /// invalidation having landed before their own state transition
    /// read from the bearer store on their next protected call, which
    /// is naturally ordered-after by the actor queue.
    public typealias SessionExpiryHandler = @Sendable () async -> Void

    /// Package-internal so the composition-invariants test suite can
    /// assert that pairing clients share a single signed transport.
    /// A shipping product target cannot reach this property (no
    /// ``@testable import CatLaserAuth`` in release code), so the
    /// exposed reference does not weaken the public API surface.
    let underlying: any HTTPClient
    private let store: any BearerTokenStore
    private let attestationProvider: any DeviceAttestationProviding
    private let clock: @Sendable () -> Date
    private let uuidFactory: @Sendable () -> UUID
    private let onSessionExpired: SessionExpiryHandler?

    /// Package-private designated initializer. Tests inject a fixed clock
    /// so they can assert the exact `api:<ts>` timestamp threaded into
    /// each attestation, and a seeded UUID factory so they can assert
    /// the exact `Idempotency-Key` without relying on the OS RNG. Also
    /// used by tests that want to intercept the post-sign wire bytes
    /// with a `MockHTTPClient`; the test target reaches this initializer
    /// via `@testable import CatLaserAuth`. Not public so a release
    /// build of `CatLaserApp` / `CatLaserPairing` cannot accidentally
    /// wire an unpinned transport into the protected call path.
    init(
        underlying: any HTTPClient,
        store: any BearerTokenStore,
        attestationProvider: any DeviceAttestationProviding,
        clock: @escaping @Sendable () -> Date,
        uuidFactory: @escaping @Sendable () -> UUID,
        onSessionExpired: SessionExpiryHandler? = nil,
    ) {
        self.underlying = underlying
        self.store = store
        self.attestationProvider = attestationProvider
        self.clock = clock
        self.uuidFactory = uuidFactory
        self.onSessionExpired = onSessionExpired
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let session: AuthSession?
        do {
            session = try await store.load()
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.providerInternal("bearer store read: \(error.localizedDescription)")
        }
        guard let session else {
            throw AuthError.missingBearerToken
        }
        let bearer = session.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bearer.isEmpty else {
            throw AuthError.missingBearerToken
        }

        let timestamp = try plausibleTimestamp()
        let attestationHeader = try await attestationProvider.currentAttestationHeader(
            binding: .api(timestamp: timestamp),
        )

        var signed = request
        signed.setValue("Bearer \(bearer)", forHTTPHeaderField: Self.authorizationHeaderName)
        signed.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)

        if Self.isMutating(method: request.httpMethod) {
            let resolvedKey = try Self.resolveIdempotencyKey(
                existing: signed.value(forHTTPHeaderField: Self.idempotencyHeaderName),
                uuidFactory: uuidFactory,
            )
            signed.setValue(resolvedKey, forHTTPHeaderField: Self.idempotencyHeaderName)
        } else {
            // Defence in depth: a stray `Idempotency-Key` on a read
            // would trip the server's "mutating-only" check only if the
            // wrapper happened to pass through caller-supplied read
            // headers verbatim. Strip it so a refactor that starts
            // attaching keys indiscriminately can't accidentally change
            // the server-facing contract.
            signed.setValue(nil, forHTTPHeaderField: Self.idempotencyHeaderName)
        }

        let response = try await underlying.send(signed)
        if response.statusCode == 401, let onSessionExpired {
            // Fire the expiry callback on EVERY observed 401, regardless
            // of response body. The callback drives
            // `AuthCoordinator.handleSessionExpired()` — invalidating the
            // in-memory bearer cache and notifying lifecycle observers.
            // It runs in its own Task so a slow observer never stalls
            // the caller's response handling; the response itself is
            // propagated unmodified so the caller sees the 401 and maps
            // it to its domain error (`PairingError.sessionExpired`,
            // etc.) as before.
            Task { await onSessionExpired() }
        }
        return response
    }

    private func plausibleTimestamp() throws(AuthError) -> Int64 {
        let timestamp = Int64(clock().timeIntervalSince1970)
        guard timestamp >= AuthCoordinator.minPlausibleRequestTimestamp,
              timestamp <= AuthCoordinator.maxPlausibleRequestTimestamp
        else {
            throw .attestationFailed(
                "system clock reports an implausible Unix-seconds value (\(timestamp));"
                    + " expected ["
                    + "\(AuthCoordinator.minPlausibleRequestTimestamp), "
                    + "\(AuthCoordinator.maxPlausibleRequestTimestamp)]",
            )
        }
        return timestamp
    }

    static func isMutating(method: String?) -> Bool {
        guard let method, !method.isEmpty else {
            // Foundation's `URLRequest` defaults `httpMethod` to "GET"
            // when unset, so a nil here only happens if the caller
            // explicitly wrote nil back. Treat it as a read — safer
            // than auto-attaching an idempotency key to an ambiguous
            // request.
            return false
        }
        return mutatingMethods.contains(method.uppercased())
    }

    static func resolveIdempotencyKey(
        existing: String?,
        uuidFactory: @Sendable () -> UUID,
    ) throws(AuthError) -> String {
        if let existing {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw .attestationFailed("caller-supplied Idempotency-Key is empty")
            }
            guard isValidIdempotencyKey(trimmed) else {
                throw .attestationFailed(
                    "caller-supplied Idempotency-Key is not an RFC 4122 UUID (8-4-4-4-12 hex)",
                )
            }
            return trimmed
        }
        let generated = uuidFactory().uuidString.lowercased()
        // Swift's `UUID.uuidString` is always canonical 8-4-4-4-12
        // uppercase hex; lowercasing still matches the server's
        // case-insensitive regex. Re-validate defensively in case a
        // test injects a degenerate factory — the invariant we need
        // on the wire is "server-accepted format", not "Foundation's
        // promise".
        guard isValidIdempotencyKey(generated) else {
            throw .attestationFailed(
                "generated Idempotency-Key is not an RFC 4122 UUID (8-4-4-4-12 hex): \(generated)",
            )
        }
        return generated
    }

    private static let idempotencyKeyRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: idempotencyKeyPattern, options: [.caseInsensitive])
    }()

    static func isValidIdempotencyKey(_ candidate: String) -> Bool {
        guard let regex = idempotencyKeyRegex else { return false }
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return regex.firstMatch(in: candidate, options: [], range: range) != nil
    }
}

#if canImport(Security) && canImport(Darwin)
public extension SignedHTTPClient {
    /// Production-facing public initializer. Requires a concrete
    /// `PinnedHTTPClient` — SPKI-SHA256 pinning is a type-system
    /// invariant on this path. A caller that wants to wrap an unpinned
    /// `URLSession` or a test mock must instead reach the
    /// package-private `init(underlying:...)` via `@testable import
    /// CatLaserAuth`, which the product target cannot do.
    ///
    /// The `onSessionExpired` callback is fired every time the server
    /// returns HTTP 401 on a signed call. The composition root binds
    /// it to `AuthCoordinator.handleSessionExpired()` so a rejected
    /// bearer invalidates the in-memory cache and notifies lifecycle
    /// observers. Passing `nil` disables the notification — useful
    /// only for tests or for composition paths that do not have an
    /// auth coordinator wired yet; a release build MUST pass a
    /// non-nil handler or a 401 will leave the in-memory cache
    /// serving the rejected bearer until the next explicit
    /// invalidation.
    init(
        transport: PinnedHTTPClient,
        store: any BearerTokenStore,
        attestationProvider: any DeviceAttestationProviding,
        onSessionExpired: SessionExpiryHandler? = nil,
    ) {
        self.init(
            underlying: transport,
            store: store,
            attestationProvider: attestationProvider,
            clock: { Date() },
            uuidFactory: { UUID() },
            onSessionExpired: onSessionExpired,
        )
    }
}
#endif
