import CatLaserObservability
import Foundation
import Testing

@Suite("ObservabilityConfig")
struct ObservabilityConfigTests {
    private func minimalPaths() -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-cfg-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("breadcrumbs.json"),
            root.appendingPathComponent("Tombstones", isDirectory: true),
            root.appendingPathComponent("events.ndjson"),
        )
    }

    @Test
    func rejectsNonHTTPSTelemetryURL() {
        let (breadcrumbs, tombstones, queue) = minimalPaths()
        do {
            _ = try ObservabilityConfig(
                telemetryURL: URL(string: "http://api.example.com/events")!,
                crashURL: URL(string: "https://api.example.com/crashes")!,
                deviceIDSalt: "salt",
                appVersion: "1.0.0",
                buildNumber: "1",
                bundleID: "com.catlaser.app",
                breadcrumbsURL: breadcrumbs,
                tombstoneDirectory: tombstones,
                queueURL: queue,
            )
            Issue.record("expected throw on http scheme")
        } catch ObservabilityConfigError.insecureTelemetryURL {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func rejectsNonHTTPSCrashURL() {
        let (breadcrumbs, tombstones, queue) = minimalPaths()
        do {
            _ = try ObservabilityConfig(
                telemetryURL: URL(string: "https://api.example.com/events")!,
                crashURL: URL(string: "http://api.example.com/crashes")!,
                deviceIDSalt: "salt",
                appVersion: "1.0.0",
                buildNumber: "1",
                bundleID: "com.catlaser.app",
                breadcrumbsURL: breadcrumbs,
                tombstoneDirectory: tombstones,
                queueURL: queue,
            )
            Issue.record("expected throw on http scheme")
        } catch ObservabilityConfigError.insecureCrashURL {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func rejectsEmptySalt() {
        let (breadcrumbs, tombstones, queue) = minimalPaths()
        do {
            _ = try ObservabilityConfig(
                telemetryURL: URL(string: "https://api.example.com/events")!,
                crashURL: URL(string: "https://api.example.com/crashes")!,
                deviceIDSalt: "",
                appVersion: "1.0.0",
                buildNumber: "1",
                bundleID: "com.catlaser.app",
                breadcrumbsURL: breadcrumbs,
                tombstoneDirectory: tombstones,
                queueURL: queue,
            )
            Issue.record("expected throw on empty salt")
        } catch ObservabilityConfigError.missingSalt {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func rejectsEmptyVersion() {
        let (breadcrumbs, tombstones, queue) = minimalPaths()
        do {
            _ = try ObservabilityConfig(
                telemetryURL: URL(string: "https://api.example.com/events")!,
                crashURL: URL(string: "https://api.example.com/crashes")!,
                deviceIDSalt: "salt",
                appVersion: "   ",
                buildNumber: "1",
                bundleID: "com.catlaser.app",
                breadcrumbsURL: breadcrumbs,
                tombstoneDirectory: tombstones,
                queueURL: queue,
            )
            Issue.record("expected throw on empty version")
        } catch ObservabilityConfigError.missingVersion {
            // ok
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test
    func derivedFactoryComposesURLsFromBaseURL() throws {
        let base = URL(string: "https://api.example.com")!
        let cfg = try ObservabilityConfig.derived(
            baseURL: base,
            deviceIDSalt: "salt",
            appVersion: "1.0.0",
            buildNumber: "1",
            bundleID: "com.catlaser.app",
        )
        #expect(cfg.telemetryURL.absoluteString.hasSuffix("/api/v1/observability/events"))
        #expect(cfg.crashURL.absoluteString.hasSuffix("/api/v1/observability/crashes"))
        #expect(cfg.telemetryURL.scheme == "https")
        #expect(cfg.crashURL.scheme == "https")
        // Storage dirs live under the caches tree — a derived path,
        // not Documents. Documents would back up to iCloud which is
        // not where a crash log should go.
        #expect(cfg.breadcrumbsURL.lastPathComponent == "breadcrumbs.json")
        #expect(cfg.queueURL.lastPathComponent == "events.ndjson")
    }
}
