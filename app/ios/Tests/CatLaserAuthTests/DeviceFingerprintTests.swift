import Foundation
import Testing

@testable import CatLaserAuth

private func makeFingerprint(installID: String = "01234567-89AB-CDEF-0123-456789ABCDEF") -> DeviceFingerprint {
    DeviceFingerprint(
        platform: "ios",
        model: "iPhone15,4",
        systemName: "iOS",
        osVersion: "17.4.1",
        locale: "en_US",
        timezone: "America/Denver",
        appVersion: "1.0.0",
        appBuild: "42",
        bundleID: "com.catlaser.app",
        installID: installID,
    )
}

@Suite("DeviceFingerprint encoder")
struct DeviceFingerprintEncoderTests {
    @Test
    func jsonShapeIsStableAndSortedKeys() throws {
        let fingerprint = makeFingerprint()
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        let data = try #require(Data(base64Encoded: header))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == """
        {"appBuild":"42","appVersion":"1.0.0","bundleID":"com.catlaser.app","installID":"01234567-89AB-CDEF-0123-456789ABCDEF","locale":"en_US","model":"iPhone15,4","osVersion":"17.4.1","platform":"ios","systemName":"iOS","timezone":"America/Denver"}
        """)
    }

    @Test
    func headerIsPlainAsciiBase64() throws {
        let fingerprint = makeFingerprint()
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        #expect(header.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test
    func headerRoundTripsThroughDecoder() throws {
        let fingerprint = makeFingerprint()
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        let decoded = try DeviceFingerprintEncoder.decodeHeaderValue(header)
        #expect(decoded == fingerprint)
    }

    @Test
    func headerStaysWellBelowHTTPLimit() throws {
        let fingerprint = makeFingerprint()
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        #expect(header.utf8.count < 1024, "expected < 1 KiB, got \(header.utf8.count) bytes")
        #expect(header.utf8.count <= DeviceFingerprintEncoder.maxHeaderValueBytes)
    }

    @Test
    func identicalInputsProduceIdenticalHeaders() throws {
        let fingerprint = makeFingerprint()
        let a = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        let b = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        #expect(a == b, "encoder must be deterministic for server-side byte comparison")
    }

    @Test
    func differentInstallIDProducesDifferentHeader() throws {
        let a = try DeviceFingerprintEncoder.encodeHeaderValue(makeFingerprint(installID: "a-id"))
        let b = try DeviceFingerprintEncoder.encodeHeaderValue(makeFingerprint(installID: "b-id"))
        #expect(a != b)
    }

    @Test
    func oversizeFingerprintIsRejected() {
        let huge = String(repeating: "x", count: DeviceFingerprintEncoder.maxHeaderValueBytes)
        let fingerprint = DeviceFingerprint(
            platform: "ios",
            model: huge,
            systemName: "iOS",
            osVersion: "17",
            locale: "en",
            timezone: "UTC",
            appVersion: "1",
            appBuild: "1",
            bundleID: "a",
            installID: "b",
        )
        do {
            _ = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
            Issue.record("expected oversize header to be rejected")
        } catch let AuthError.fingerprintCaptureFailed(message) {
            #expect(message.contains("exceeds"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func invalidBase64HeaderIsRejected() {
        do {
            _ = try DeviceFingerprintEncoder.decodeHeaderValue("not$$base64!!")
            Issue.record("expected decode failure")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg.contains("base64") || msg.contains("decode"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func notJSONHeaderIsRejected() throws {
        let notJSON = Data("not json at all".utf8).base64EncodedString()
        do {
            _ = try DeviceFingerprintEncoder.decodeHeaderValue(notJSON)
            Issue.record("expected decode failure")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg.contains("decode"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func fingerprintEquatesStructurally() {
        let a = makeFingerprint()
        let b = makeFingerprint()
        let c = makeFingerprint(installID: "different")
        #expect(a == b)
        #expect(a != c)
    }

    @Test
    func allSchemaKeysArePresent() throws {
        let fingerprint = makeFingerprint()
        let header = try DeviceFingerprintEncoder.encodeHeaderValue(fingerprint)
        let data = try #require(Data(base64Encoded: header))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
        )
        let expectedKeys: Set<String> = [
            "platform", "model", "systemName", "osVersion",
            "locale", "timezone",
            "appVersion", "appBuild", "bundleID", "installID",
        ]
        #expect(Set(parsed.keys) == expectedKeys)
    }
}

@Suite("SystemDeviceFingerprintProvider")
struct SystemDeviceFingerprintProviderTests {
    private func makeBundle() -> Bundle {
        Bundle.main
    }

    @Test
    func systemProviderAssemblesFullFingerprint() async throws {
        let deviceInfo = DeviceInfo(
            platform: "ios",
            model: "iPhone15,4",
            systemName: "iOS",
            osVersion: "17.4.1",
        )
        let store = InMemoryInstallIDStore(initial: "fixed-install-id")
        let provider = SystemDeviceFingerprintProvider(
            installIDStore: store,
            bundle: makeBundle(),
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "America/Denver")! },
            deviceInfo: deviceInfo,
        )
        let fingerprint = try await provider.currentFingerprint()
        #expect(fingerprint.platform == "ios")
        #expect(fingerprint.model == "iPhone15,4")
        #expect(fingerprint.systemName == "iOS")
        #expect(fingerprint.osVersion == "17.4.1")
        #expect(fingerprint.locale == "en_US")
        #expect(fingerprint.timezone == "America/Denver")
        #expect(fingerprint.installID == "fixed-install-id")
    }

    @Test
    func twoCallsReturnSameInstallID() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s", osVersion: "v")
        let store = InMemoryInstallIDStore()
        let provider = SystemDeviceFingerprintProvider(
            installIDStore: store,
            bundle: makeBundle(),
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "UTC")! },
            deviceInfo: deviceInfo,
        )
        let first = try await provider.currentFingerprint()
        let second = try await provider.currentFingerprint()
        #expect(first.installID == second.installID)
        #expect(!first.installID.isEmpty)
    }

    @Test
    func providerRejectsEmptyInstallID() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s", osVersion: "v")
        // Seed the store with an empty value by injecting a generator that returns "".
        let store = InMemoryInstallIDStore(initial: nil, generator: { "" })
        let provider = SystemDeviceFingerprintProvider(
            installIDStore: store,
            bundle: makeBundle(),
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "UTC")! },
            deviceInfo: deviceInfo,
        )
        do {
            _ = try await provider.currentFingerprint()
            Issue.record("expected fingerprintCaptureFailed")
        } catch let AuthError.fingerprintCaptureFailed(msg) {
            #expect(msg.contains("empty"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func currentFingerprintHeaderMatchesManualEncode() async throws {
        let deviceInfo = DeviceInfo(platform: "ios", model: "m", systemName: "s", osVersion: "v")
        let store = InMemoryInstallIDStore(initial: "id-1")
        let provider = SystemDeviceFingerprintProvider(
            installIDStore: store,
            bundle: makeBundle(),
            localeProvider: { Locale(identifier: "en_US") },
            timezoneProvider: { TimeZone(identifier: "UTC")! },
            deviceInfo: deviceInfo,
        )
        let header = try await provider.currentFingerprintHeader()
        let manualFingerprint = try await provider.currentFingerprint()
        let manualHeader = try DeviceFingerprintEncoder.encodeHeaderValue(manualFingerprint)
        #expect(header == manualHeader)
    }
}

@Suite("StubDeviceFingerprintProvider")
struct StubDeviceFingerprintProviderTests {
    @Test
    func stubReturnsConfiguredFingerprint() async throws {
        let fingerprint = makeFingerprint()
        let provider = StubDeviceFingerprintProvider(fingerprint: fingerprint)
        let result = try await provider.currentFingerprint()
        #expect(result == fingerprint)
    }
}
