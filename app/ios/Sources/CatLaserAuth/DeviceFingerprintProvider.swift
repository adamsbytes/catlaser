import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public protocol DeviceFingerprintProviding: Sendable {
    func currentFingerprint() async throws -> DeviceFingerprint
    func currentFingerprintHeader() async throws -> String
}

public extension DeviceFingerprintProviding {
    func currentFingerprintHeader() async throws -> String {
        let fingerprint = try await currentFingerprint()
        return try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
    }
}

/// Default provider used at runtime. Reads device metadata from UIDevice /
/// ProcessInfo / Bundle / Locale, and pulls the persistent install ID from a
/// `InstallIDStoring` implementation (Keychain-backed in production).
///
/// The provider is deterministic under a fixed input: two calls on the same
/// device with the same install ID produce identical fingerprints, so the
/// server can compare request-time and completion-time payloads byte-for-byte
/// where desired.
public struct SystemDeviceFingerprintProvider: DeviceFingerprintProviding {
    private let installIDStore: any InstallIDStoring
    private let bundle: Bundle
    private let localeProvider: @Sendable () -> Locale
    private let timezoneProvider: @Sendable () -> TimeZone
    private let deviceInfo: DeviceInfo

    public init(
        installIDStore: any InstallIDStoring,
        bundle: Bundle = .main,
    ) {
        self.init(
            installIDStore: installIDStore,
            bundle: bundle,
            localeProvider: { Locale.current },
            timezoneProvider: { TimeZone.current },
            deviceInfo: SystemDeviceFingerprintProvider.platformDeviceInfo(),
        )
    }

    init(
        installIDStore: any InstallIDStoring,
        bundle: Bundle,
        localeProvider: @escaping @Sendable () -> Locale,
        timezoneProvider: @escaping @Sendable () -> TimeZone,
        deviceInfo: DeviceInfo,
    ) {
        self.installIDStore = installIDStore
        self.bundle = bundle
        self.localeProvider = localeProvider
        self.timezoneProvider = timezoneProvider
        self.deviceInfo = deviceInfo
    }

    public func currentFingerprint() async throws -> DeviceFingerprint {
        let installID = try await installIDStore.currentID()
        guard !installID.isEmpty else {
            throw AuthError.fingerprintCaptureFailed("install ID store returned empty value")
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

extension SystemDeviceFingerprintProvider {
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

/// Deterministic provider used in tests. Returns whatever fingerprint is
/// configured on construction, without touching UIKit or the install-ID store.
public struct StubDeviceFingerprintProvider: DeviceFingerprintProviding {
    private let fingerprint: DeviceFingerprint

    public init(fingerprint: DeviceFingerprint) {
        self.fingerprint = fingerprint
    }

    public func currentFingerprint() async throws -> DeviceFingerprint {
        fingerprint
    }
}
