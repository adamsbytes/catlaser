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
            name: "CatLaserApp",
            targets: ["CatLaserApp"],
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
        .target(
            name: "CatLaserApp",
            dependencies: [
                "CatLaserAuth",
                "CatLaserDevice",
                "CatLaserLive",
                "CatLaserPairing",
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
                "CatLaserLive",
                "CatLaserPairing",
                "CatLaserDevice",
                "CatLaserDeviceTestSupport",
                "CatLaserProto",
            ],
            path: "Tests/CatLaserAppTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
