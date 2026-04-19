import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Builds the per-installation ``ObservabilityContext`` used by every
/// upload. The context exists to give the ingest side a stable
/// device identity without ever sending the raw
/// ``identifierForVendor`` over the wire.
///
/// ## Hashing
///
/// Raw device identifiers are out-of-scope for telemetry: they
/// uniquely identify an installation and the server does not need
/// that level of resolution. The context therefore hashes the
/// identifier with SHA-256 alongside a caller-supplied per-app salt.
/// The salt is a constant baked into ``ObservabilityConfig`` — it
/// frustrates cross-app correlation (two catlaser deployments with
/// different salts produce different hashes for the same device)
/// without making dedup impossible.
///
/// On Linux (SPM CI) there is no Apple vendor ID; the builder falls
/// back to a deterministic per-process UUID so the test runner can
/// still construct a context without pretending to be a device.
public enum DeviceContextBuilder {
    /// Construct a context for the current process + device.
    public static func current(
        sessionID: String,
        config: ObservabilityConfig,
    ) -> ObservabilityContext {
        ObservabilityContext(
            deviceIDHash: hashedDeviceID(salt: config.deviceIDSalt),
            sessionID: sessionID,
            appVersion: config.appVersion,
            buildNumber: config.buildNumber,
            bundleID: config.bundleID,
            platform: platformName,
            osVersion: osVersionString,
            deviceModel: deviceModelString,
            locale: Locale.current.identifier,
        )
    }

    /// SHA-256(vendorIdentifier || ':' || salt), base-64 URL-safe,
    /// no padding. Stable per-install on iOS; regenerated on every
    /// reinstall (as per `identifierForVendor` semantics) so a
    /// fresh install looks like a new device — exactly what the
    /// ingest side expects.
    public static func hashedDeviceID(salt: String) -> String {
        let identifier = rawDeviceIdentifier()
        let composed = "\(identifier):\(salt)"
        guard let bytes = composed.data(using: .utf8) else {
            return ""
        }
        let digest = SHA256.hash(data: bytes)
        return Self.base64URL(from: Data(digest))
    }

    private static func rawDeviceIdentifier() -> String {
        #if canImport(UIKit) && !os(watchOS)
        // `identifierForVendor` is the Apple-sanctioned device
        // identity for apps from the same vendor. It rotates on
        // uninstall / reinstall, which is the right behaviour for
        // crash-rate baselining.
        if let uuid = UIDevice.current.identifierForVendor {
            return uuid.uuidString
        }
        return "unknown"
        #else
        // Deterministic fallback for SPM Linux CI.
        return "linux-ci"
        #endif
    }

    /// Base-64 URL-safe, no padding. Matches RFC 4648 §5.
    private static func base64URL(from data: Data) -> String {
        var encoded = data.base64EncodedString()
        encoded = encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.hasSuffix("=") {
            encoded.removeLast()
        }
        return encoded
    }

    private static var platformName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }

    private static var osVersionString: String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// Hardware model string. On iOS this resolves via `uname` to
    /// the machine code (e.g. `iPhone15,2`), not the human-readable
    /// marketing name — so an analyst joining the value against
    /// Apple's published machine table gets the exact device.
    private static var deviceModelString: String {
        #if canImport(Darwin)
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        var bytes: [UInt8] = []
        for child in mirror.children {
            guard let value = child.value as? Int8 else { continue }
            if value == 0 { break }
            bytes.append(UInt8(bitPattern: value))
        }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return "linux-ci"
        #endif
    }
}
