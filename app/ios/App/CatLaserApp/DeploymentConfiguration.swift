import CatLaserApp
import CatLaserAuth
import CatLaserLive
import CatLaserObservability
import Foundation

/// Reads the Info.plist entries the xcconfig inflates at build time
/// and constructs the ``AppComposition/DeploymentConfig`` the shipping
/// app target feeds into ``AppComposition/production``.
///
/// Every Info.plist key is prefixed ``CATLASER_`` so a grep finds the
/// full set in one shot and none of them collides with Apple-reserved
/// keys. Each key maps 1:1 to an xcconfig variable of the same name.
///
/// ## Failure posture
///
/// Construction is fail-loud on every malformed or missing field.
/// A release build that was not re-signed with real TLS pins / auth
/// hosts throws ``DeploymentConfigurationError`` at launch; the app
/// crashes before the first view is drawn, with a clear message in
/// the crash log. This is deliberate — a silently-launched app with
/// placeholder pins would accept any server certificate, and a
/// placeholder coordination-server URL would surface as "everything
/// fails" rather than "you forgot to swap the xcconfig."
///
/// The checked-in xcconfig ships with placeholder values that are
/// *syntactically valid* (so Xcode's build still succeeds without a
/// developer editing the file) but obviously fake; see the TODO
/// block at the bottom of ``docs/BUILD.md`` for the full list of
/// values the operator must swap before TestFlight.
enum DeploymentConfiguration {
    /// Load the deployment config from ``Bundle.main``. Throws on any
    /// missing or malformed entry; callers that treat failure as a
    /// launch-blocker should simply ``try await`` and let the
    /// exception propagate to an explicit `preconditionFailure`.
    static func load(
        bundle: Bundle = .main,
    ) throws(DeploymentConfigurationError) -> AppComposition.DeploymentConfig {
        let bundleID = try readString(bundle, key: "CFBundleIdentifier", reason: .missingBundleID)
        let appVersion = try readString(
            bundle,
            key: "CFBundleShortVersionString",
            reason: .missingAppVersion,
        )
        let buildNumber = try readString(
            bundle,
            key: "CFBundleVersion",
            reason: .missingBuildNumber,
        )

        let authBaseString = try readString(
            bundle,
            key: "CATLASER_AUTH_BASE_URL",
            reason: .missingAuthBaseURL,
        )
        guard let authBaseURL = URL(string: authBaseString),
              authBaseURL.scheme?.lowercased() == "https"
        else {
            throw .malformedAuthBaseURL(authBaseString)
        }

        let appleServiceID = try readString(
            bundle,
            key: "CATLASER_AUTH_APPLE_SERVICE_ID",
            reason: .missingAppleServiceID,
        )
        let googleClientID = try readString(
            bundle,
            key: "CATLASER_AUTH_GOOGLE_CLIENT_ID",
            reason: .missingGoogleClientID,
        )
        let universalLinkHost = try readString(
            bundle,
            key: "CATLASER_AUTH_UNIVERSAL_LINK_HOST",
            reason: .missingUniversalLinkHost,
        )
        let universalLinkPath = try readString(
            bundle,
            key: "CATLASER_AUTH_UNIVERSAL_LINK_PATH",
            reason: .missingUniversalLinkPath,
        )
        let oauthRedirectHosts = try readList(
            bundle,
            key: "CATLASER_AUTH_OAUTH_REDIRECT_HOSTS",
            reason: .missingOAuthRedirectHosts,
        )

        let authConfig: AuthConfig
        do {
            authConfig = try AuthConfig(
                baseURL: authBaseURL,
                appleServiceID: appleServiceID,
                googleClientID: googleClientID,
                bundleID: bundleID,
                universalLinkHost: universalLinkHost,
                universalLinkPath: universalLinkPath,
                oauthRedirectHosts: Set(oauthRedirectHosts),
            )
        } catch {
            throw .authConfig(error)
        }

        let pinBlobs = try readList(
            bundle,
            key: "CATLASER_TLS_SPKI_SHA256_PINS",
            reason: .missingTLSPins,
        )
        let pins: [TLSPin]
        do {
            pins = try pinBlobs.enumerated().map { index, blob in
                guard let data = Data(base64Encoded: blob) else {
                    throw DeploymentConfigurationError.malformedTLSPin(index: index, value: blob)
                }
                return try TLSPin(spkiSHA256: data, label: "xcconfig-pin-\(index)")
            }
        } catch let error as DeploymentConfigurationError {
            throw error
        } catch let error as TLSPin.InitError {
            throw .tlsPinInit(error)
        } catch {
            throw .tlsPinInit(.wrongDigestLength(-1))
        }
        let tlsPinning: TLSPinning
        do {
            tlsPinning = try TLSPinning(pins: pins)
        } catch {
            throw .tlsPinningInit(error)
        }

        let liveKitHosts = try readList(
            bundle,
            key: "CATLASER_LIVEKIT_HOSTS",
            reason: .missingLiveKitHosts,
        )
        let liveKitAllowlist: LiveKitHostAllowlist
        do {
            liveKitAllowlist = try LiveKitHostAllowlist(hosts: liveKitHosts)
        } catch {
            throw .liveKitAllowlist(error)
        }

        let deviceIDSalt = try readString(
            bundle,
            key: "CATLASER_OBSERVABILITY_DEVICE_ID_SALT",
            reason: .missingObservabilitySalt,
        )
        let observabilityConfig: ObservabilityConfig
        do {
            observabilityConfig = try ObservabilityConfig.derived(
                baseURL: authBaseURL,
                deviceIDSalt: deviceIDSalt,
                appVersion: appVersion,
                buildNumber: buildNumber,
                bundleID: bundleID,
            )
        } catch {
            throw .observabilityConfig(error)
        }

        return AppComposition.DeploymentConfig(
            authConfig: authConfig,
            tlsPinning: tlsPinning,
            liveKitAllowlist: liveKitAllowlist,
            observabilityConfig: observabilityConfig,
        )
    }

    // MARK: - Readers

    private static func readString(
        _ bundle: Bundle,
        key: String,
        reason: DeploymentConfigurationError,
    ) throws(DeploymentConfigurationError) -> String {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw reason }
        return trimmed
    }

    /// Read a comma-separated Info.plist string into a de-duplicated
    /// array, trimming whitespace around each entry. The xcconfig
    /// format uses comma-separated values because xcconfig does not
    /// natively support arrays; Info.plist array entries would work
    /// too but would double the surface area (string + array).
    private static func readList(
        _ bundle: Bundle,
        key: String,
        reason: DeploymentConfigurationError,
    ) throws(DeploymentConfigurationError) -> [String] {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw reason }
        var seen: Set<String> = []
        let parts = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !parts.isEmpty else { throw reason }
        return parts
    }

    /// Short application-version + build-number tuple, surfaced on
    /// the Settings screen.
    static func versionTuple(bundle: Bundle = .main) -> (String, String) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return (version ?? "0.0.0", build ?? "0")
    }

    /// Read the legal URL pair (privacy policy, terms of service) that
    /// the Settings → About section links to. Both keys are required
    /// and both values must be absolute ``https://`` URLs — App Store
    /// review rejects apps whose in-app legal links 404, and a plain
    /// HTTP URL would be a downgrade attack surface. Failure here is
    /// treated the same as any other deployment-config miss: the call
    /// site fails loud at launch so a mis-built archive never ships.
    static func legalURLs(
        bundle: Bundle = .main,
    ) throws(DeploymentConfigurationError) -> LegalURLs {
        let privacyString = try readString(
            bundle,
            key: "CATLASER_PRIVACY_POLICY_URL",
            reason: .missingPrivacyPolicyURL,
        )
        guard let privacyURL = URL(string: privacyString),
              privacyURL.scheme?.lowercased() == "https"
        else {
            throw .malformedPrivacyPolicyURL(privacyString)
        }
        let termsString = try readString(
            bundle,
            key: "CATLASER_TERMS_OF_SERVICE_URL",
            reason: .missingTermsOfServiceURL,
        )
        guard let termsURL = URL(string: termsString),
              termsURL.scheme?.lowercased() == "https"
        else {
            throw .malformedTermsOfServiceURL(termsString)
        }
        return LegalURLs(privacyPolicy: privacyURL, termsOfService: termsURL)
    }
}

/// Public-facing legal URLs surfaced on the Settings screen. Both are
/// required at launch — App Store Review 5.1.1 requires these links
/// from any app that collects user data or offers account creation.
struct LegalURLs: Sendable, Equatable {
    let privacyPolicy: URL
    let termsOfService: URL
}

/// Typed failure surface for ``DeploymentConfiguration/load()``.
///
/// Every missing / malformed key has a distinct case so the launch
/// failure message points an operator at the exact xcconfig entry to
/// fix. Inspect the raw value of each associated type in the crash
/// log to see which key is broken.
enum DeploymentConfigurationError: Error {
    case missingBundleID
    case missingAppVersion
    case missingBuildNumber
    case missingAuthBaseURL
    case malformedAuthBaseURL(String)
    case missingAppleServiceID
    case missingGoogleClientID
    case missingUniversalLinkHost
    case missingUniversalLinkPath
    case missingOAuthRedirectHosts
    case missingTLSPins
    case malformedTLSPin(index: Int, value: String)
    case missingLiveKitHosts
    case missingObservabilitySalt
    case missingPrivacyPolicyURL
    case malformedPrivacyPolicyURL(String)
    case missingTermsOfServiceURL
    case malformedTermsOfServiceURL(String)
    case authConfig(AuthConfigError)
    case tlsPinInit(TLSPin.InitError)
    case tlsPinningInit(TLSPinning.InitError)
    case liveKitAllowlist(LiveKitHostAllowlistError)
    case observabilityConfig(ObservabilityConfigError)
}
