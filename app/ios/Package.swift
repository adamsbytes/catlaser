// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CatLaser",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CatLaserProto",
            targets: ["CatLaserProto"],
        ),
        .library(
            name: "CatLaserAuth",
            targets: ["CatLaserAuth"],
        ),
        .library(
            name: "CatLaserDevice",
            targets: ["CatLaserDevice"],
        ),
        .library(
            name: "CatLaserLive",
            targets: ["CatLaserLive"],
        ),
        .library(
            name: "CatLaserPairing",
            targets: ["CatLaserPairing"],
        ),
        .library(
            name: "CatLaserHistory",
            targets: ["CatLaserHistory"],
        ),
        .library(
            name: "CatLaserSchedule",
            targets: ["CatLaserSchedule"],
        ),
        .library(
            name: "CatLaserPush",
            targets: ["CatLaserPush"],
        ),
        .library(
            name: "CatLaserApp",
            targets: ["CatLaserApp"],
        ),
        .library(
            name: "CatLaserDesign",
            targets: ["CatLaserDesign"],
        ),
        .library(
            name: "CatLaserObservability",
            targets: ["CatLaserObservability"],
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.30.0",
        ),
        .package(
            url: "https://github.com/openid/AppAuth-iOS.git",
            from: "2.0.0",
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            from: "3.0.0",
        ),
    ],
    targets: [
        .target(
            name: "CatLaserProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/CatLaserProto",
        ),
        .testTarget(
            name: "CatLaserProtoTests",
            dependencies: ["CatLaserProto"],
            path: "Tests/CatLaserProtoTests",
        ),
        .target(
            name: "CatLaserAuth",
            dependencies: [
                .product(
                    name: "AppAuth",
                    package: "AppAuth-iOS",
                    condition: .when(platforms: [.iOS, .macOS]),
                ),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi]),
                ),
            ],
            path: "Sources/CatLaserAuth",
        ),
        // Test-only. Holds `SoftwareIdentityStore`, the in-memory P-256
        // identity used by unit tests that cannot reach the Secure
        // Enclave (SPM test runners, Linux CI). Deliberately NOT listed
        // in `products:` above — external consumers of this package
        // (the app target, future modules) cannot import it, so there
        // is no path by which a non-SE identity can be wired into a
        // shipping build.
        .target(
            name: "CatLaserAuthTestSupport",
            dependencies: [
                "CatLaserAuth",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi]),
                ),
            ],
            path: "Sources/CatLaserAuthTestSupport",
        ),
        .testTarget(
            name: "CatLaserAuthTests",
            dependencies: [
                "CatLaserAuth",
                "CatLaserAuthTestSupport",
            ],
            path: "Tests/CatLaserAuthTests",
        ),
        // App-to-device TCP wire transport. Speaks the length-prefixed
        // protobuf framing defined in `python/catlaser_brain/network/wire.py`.
        // Cross-platform: the Network.framework-backed concrete transport
        // is `#if canImport(Network)`-gated so the library and all of its
        // pure logic (frame codec, request correlation actor) build and
        // test on Linux SPM runners.
        .target(
            name: "CatLaserDevice",
            dependencies: [
                "CatLaserProto",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi]),
                ),
            ],
            path: "Sources/CatLaserDevice",
        ),
        // Test-only. In-memory bidirectional transport + scripted-server
        // helpers that let `DeviceClient` behavior be exercised without a
        // real TCP socket. Excluded from `products:` so shipping code
        // cannot accidentally wire a mock into a release build.
        .target(
            name: "CatLaserDeviceTestSupport",
            dependencies: [
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserDeviceTestSupport",
        ),
        .testTarget(
            name: "CatLaserDeviceTests",
            dependencies: [
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserDeviceTests",
        ),
        // Live-view stack. Orchestrates `StartStreamRequest` / `StopStreamRequest`
        // on a `CatLaserDevice.DeviceClient`, then routes the returned
        // `StreamOffer` into a `LiveStreamSession` (LiveKit-backed on Apple
        // platforms; mockable anywhere). The SwiftUI `LiveView` is
        // `#if canImport(SwiftUI)`-gated; the LiveKit concrete session
        // is `#if canImport(LiveKit)`-gated and activates once the host
        // Xcode target adds the `client-sdk-swift` package — same
        // integration pattern the repo already uses for UIKit/AppKit.
        .target(
            name: "CatLaserLive",
            dependencies: [
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserLive",
        ),
        .testTarget(
            name: "CatLaserLiveTests",
            dependencies: [
                "CatLaserLive",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserLiveTests",
        ),
        // Device pairing + persistent endpoint management. Owns the
        // QR-scan → coordination-server-pair → Keychain-persist flow,
        // the auto-reconnect + heartbeat supervisor over the already-
        // paired endpoint, and the sign-out wipe hook. `AVFoundation`
        // and `UIKit` are gated with `canImport`, matching the same
        // pattern `CatLaserLive` uses for LiveKit; pure logic
        // (URL parsing, HTTP exchange, reconnect supervisor) builds
        // and tests on Linux SPM runners.
        .target(
            name: "CatLaserPairing",
            dependencies: [
                "CatLaserAuth",
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserPairing",
        ),
        // Test-only. In-memory endpoint store + a fake
        // `NetworkPathMonitor` so `ConnectionManagerTests` can simulate
        // Wi-Fi drops and restores deterministically. Excluded from
        // `products:` so shipping code cannot wire a mock into a
        // release build.
        .target(
            name: "CatLaserPairingTestSupport",
            dependencies: [
                "CatLaserPairing",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserPairingTestSupport",
        ),
        .testTarget(
            name: "CatLaserPairingTests",
            dependencies: [
                "CatLaserPairing",
                "CatLaserPairingTestSupport",
                "CatLaserAuth",
                "CatLaserAuthTestSupport",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserPairingTests",
        ),
        // History + cat profiles. Owns the Cats / Sessions screen,
        // the rename / identify-new sheets, and the unsolicited
        // ``NewCatDetected`` event subscription. Depends only on
        // ``CatLaserDevice`` (for ``DeviceClient``) and
        // ``CatLaserProto``; no UI framework imports outside the
        // ``HistoryView.swift`` SwiftUI gate, so tests run on Linux
        // SPM the same as on Darwin.
        .target(
            name: "CatLaserHistory",
            dependencies: [
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserHistory",
        ),
        .testTarget(
            name: "CatLaserHistoryTests",
            dependencies: [
                "CatLaserHistory",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserHistoryTests",
        ),
        // Schedule setup screen. Owns the ``GetScheduleRequest`` /
        // ``SetScheduleRequest`` round-trip, the in-memory draft
        // model, per-field validation, and the SwiftUI editor.
        // Depends only on ``CatLaserDevice`` (for ``DeviceClient``)
        // and ``CatLaserProto`` — the view uses SwiftUI behind a
        // ``canImport(SwiftUI)`` gate so the pure logic (VM, draft
        // set, validation, strings) builds and tests on Linux SPM
        // runners the same as on Darwin.
        .target(
            name: "CatLaserSchedule",
            dependencies: [
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserSchedule",
        ),
        .testTarget(
            name: "CatLaserScheduleTests",
            dependencies: [
                "CatLaserSchedule",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserScheduleTests",
        ),
        // APNs push-notification orchestration. Owns the
        // register/unregister round-trip to the paired device
        // (``RegisterPushTokenRequest`` / ``UnregisterPushTokenRequest``
        // over the existing data channel), the typed parse of the
        // FCM ``data`` dict that ``python/catlaser_brain/network/push.py``
        // sends, and the deep-link route a tapped notification
        // resolves to. The ``UserNotifications``-backed authorization
        // controller + delegate are ``canImport``-gated so the pure
        // logic (token hex, payload parser, registrar state machine,
        // VM) builds and tests on Linux SPM runners the same as on
        // Darwin — matching the pattern every other feature module
        // in this package follows.
        .target(
            name: "CatLaserPush",
            dependencies: [
                "CatLaserAuth",
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserProto",
            ],
            path: "Sources/CatLaserPush",
        ),
        .testTarget(
            name: "CatLaserPushTests",
            dependencies: [
                "CatLaserPush",
                "CatLaserAuth",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserPushTests",
        ),
        .target(
            name: "CatLaserApp",
            dependencies: [
                "CatLaserAuth",
                "CatLaserDesign",
                "CatLaserDevice",
                "CatLaserHistory",
                "CatLaserLive",
                "CatLaserObservability",
                "CatLaserPairing",
                "CatLaserPush",
                "CatLaserSchedule",
            ],
            path: "Sources/CatLaserApp",
        ),
        .testTarget(
            name: "CatLaserAppTests",
            dependencies: [
                "CatLaserApp",
                "CatLaserAuth",
                "CatLaserAuthTestSupport",
                // Live, pairing, device, and proto are pulled in by
                // the composition-invariants suite: it asserts that
                // the real production graph wires every cross-module
                // seam correctly (LiveKit allowlist threaded into the
                // `LiveStreamCredentials` constructor, SignedHTTPClient
                // attached to `PairingClient` / `PairedDevicesClient`,
                // the handshake builder producing a device-bound
                // attestation). Without these deps the invariant
                // suite cannot exercise the wiring end-to-end.
                "CatLaserHistory",
                "CatLaserLive",
                "CatLaserObservability",
                "CatLaserPairing",
                // Pairing test support brings the
                // ``FakeNetworkPathMonitor`` the composition's
                // production-shape ``connectionManager(for:)``
                // factory needs to construct a supervisor without
                // touching ``Network`` framework on Linux CI.
                "CatLaserPairingTestSupport",
                "CatLaserPush",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserAppTests",
        ),
        // Design system — semantic colour tokens + accessibility
        // helpers. A lightweight dependency every feature module
        // that ships a SwiftUI view imports so the light / dark
        // branching is driven by system appearance and the
        // accessibility-identifier strings stay DRY across tests.
        .target(
            name: "CatLaserDesign",
            path: "Sources/CatLaserDesign",
        ),
        .testTarget(
            name: "CatLaserDesignTests",
            dependencies: ["CatLaserDesign"],
            path: "Tests/CatLaserDesignTests",
        ),
        // Observability — first-party crash reporting (MetricKit +
        // NSException + POSIX signal handlers + breadcrumbs) and
        // strictly-typed telemetry. No third-party SDKs; everything
        // ships to the operator-run coordination server the rest of
        // the app already talks to. Depends only on Foundation +
        // (on Darwin) CryptoKit + MetricKit so the pure logic
        // (event envelopes, queue, ring, consent store) builds and
        // tests on Linux SPM runners.
        .target(
            name: "CatLaserObservability",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi]),
                ),
            ],
            path: "Sources/CatLaserObservability",
        ),
        .testTarget(
            name: "CatLaserObservabilityTests",
            dependencies: ["CatLaserObservability"],
            path: "Tests/CatLaserObservabilityTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
