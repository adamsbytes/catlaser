import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public protocol DeviceAttestationProviding: Sendable {
    func currentFingerprint() async throws -> DeviceFingerprint
    /// Build a fresh attestation bound to `binding`. The binding is mixed
    /// into the ECDSA signature input so a captured header cannot be
    /// replayed outside its original context (see `AttestationBinding`).
    func currentAttestation(binding: AttestationBinding) async throws -> DeviceAttestation
    func currentAttestationHeader(binding: AttestationBinding) async throws -> String
}

public extension DeviceAttestationProviding {
    func currentAttestationHeader(binding: AttestationBinding) async throws -> String {
        let attestation = try await currentAttestation(binding: binding)
        return try DeviceAttestationEncoder.encodeHeaderValue(attestation)
    }
}

/// Default provider used at runtime. Reads device metadata from UIDevice /
/// ProcessInfo / Bundle / Locale, pulls the install ID from the identity
/// store (Secure Enclave in production), and assembles a signed
/// attestation.
///
/// The provider is deterministic for the static fields: two calls within
/// the same app session produce identical fingerprints (and therefore
/// identical `fph` hashes). Each signature varies per call both because
/// ECDSA is non-deterministic AND because the `binding` mixed into the
/// signed message is freshness-scoped (request-time timestamp or
/// verify-time token). Server verifies each signature against the stable
/// public key rather than byte-comparing signatures.
public struct SystemDeviceAttestationProvider: DeviceAttestationProviding {
    private let identity: any DeviceIdentityStoring
    private let bundle: Bundle
    private let localeProvider: @Sendable () -> Locale
    private let timezoneProvider: @Sendable () -> TimeZone
    private let deviceInfo: DeviceInfo

    public init(
        identity: any DeviceIdentityStoring,
        bundle: Bundle = .main,
    ) {
        self.init(
            identity: identity,
            bundle: bundle,
            localeProvider: { Locale.current },
            timezoneProvider: { TimeZone.current },
            deviceInfo: SystemDeviceAttestationProvider.platformDeviceInfo(),
        )
    }

    init(
        identity: any DeviceIdentityStoring,
        bundle: Bundle,
        localeProvider: @escaping @Sendable () -> Locale,
        timezoneProvider: @escaping @Sendable () -> TimeZone,
        deviceInfo: DeviceInfo,
    ) {
        self.identity = identity
        self.bundle = bundle
        self.localeProvider = localeProvider
        self.timezoneProvider = timezoneProvider
        self.deviceInfo = deviceInfo
    }

    public func currentFingerprint() async throws -> DeviceFingerprint {
        let installID = try await identity.installID()
        guard !installID.isEmpty else {
            throw AuthError.attestationFailed("identity store returned empty install ID")
        }

        let appVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let appBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let bundleID = bundle.bundleIdentifier ?? ""

        return DeviceFingerprint(
            platform: deviceInfo.platform,
            model: deviceInfo.model,
            systemName: deviceInfo.systemName,
            osVersion: deviceInfo.osVersion,
            locale: localeProvider().identifier,
            timezone: timezoneProvider().identifier,
            appVersion: appVersion,
            appBuild: appBuild,
            bundleID: bundleID,
            installID: installID,
        )
    }

    public func currentAttestation(binding: AttestationBinding) async throws -> DeviceAttestation {
        let fingerprint = try await currentFingerprint()
        return try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
    }
}

/// Snapshot of static device metadata. Injected to keep the provider testable
/// on platforms without UIKit/AppKit (Linux CI).
public struct DeviceInfo: Sendable, Equatable {
    public let platform: String
    public let model: String
    public let systemName: String
    public let osVersion: String

    public init(platform: String, model: String, systemName: String, osVersion: String) {
        self.platform = platform
        self.model = model
        self.systemName = systemName
        self.osVersion = osVersion
    }
}

extension SystemDeviceAttestationProvider {
    static func platformDeviceInfo() -> DeviceInfo {
        let model = hardwareModel() ?? fallbackModel()
        #if canImport(UIKit) && !os(watchOS)
        let device = UIDevice.current
        return DeviceInfo(
            platform: platformTag(),
            model: model,
            systemName: device.systemName,
            osVersion: device.systemVersion,
        )
        #else
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let systemName: String = {
            #if os(macOS)
            return "macOS"
            #elseif os(Linux)
            return "Linux"
            #elseif os(Windows)
            return "Windows"
            #else
            return "Unknown"
            #endif
        }()
        return DeviceInfo(
            platform: platformTag(),
            model: model,
            systemName: systemName,
            osVersion: version,
        )
        #endif
    }

    private static func platformTag() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #else
        return "unknown"
        #endif
    }

    /// The hardware machine identifier — e.g. `iPhone15,4`, `arm64`, `x86_64`.
    /// This is more specific than `UIDevice.current.model` which only returns
    /// `"iPhone"` / `"iPad"`.
    private static func hardwareModel() -> String? {
        #if canImport(Darwin)
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return nil }
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cStr in
                String(cString: cStr)
            }
        }
        return machine.isEmpty ? nil : machine
        #elseif canImport(Glibc) || canImport(Musl)
        return nil
        #else
        return nil
        #endif
    }

    private static func fallbackModel() -> String {
        #if os(iOS)
        return "iPhone"
        #elseif os(macOS)
        return "Mac"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }
}

/// Deterministic provider used in tests. Assembled from a preset
/// `DeviceFingerprint` plus a seeded `DeviceIdentityStoring`; produces
/// stable `fph` / `pk` bytes across calls, and valid (fresh) signatures.
public struct StubDeviceAttestationProvider: DeviceAttestationProviding {
    private let fingerprint: DeviceFingerprint
    private let identity: any DeviceIdentityStoring

    public init(fingerprint: DeviceFingerprint, identity: any DeviceIdentityStoring) {
        self.fingerprint = fingerprint
        self.identity = identity
    }

    public func currentFingerprint() async throws -> DeviceFingerprint {
        fingerprint
    }

    public func currentAttestation(binding: AttestationBinding) async throws -> DeviceAttestation {
        try await DeviceAttestationBuilder.build(
            fingerprint: fingerprint,
            identity: identity,
            binding: binding,
        )
    }
}
