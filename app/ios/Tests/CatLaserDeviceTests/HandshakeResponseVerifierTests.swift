#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatLaserProto
import Foundation
import Testing

@testable import CatLaserDevice

/// Coverage for the device-signed AuthResponse verification path.
///
/// The device-side signer and the app-side verifier both construct a
/// canonical transcript (domain separator + nonce + signed_at +
/// ok + reason). These tests exercise every failure mode the app
/// must detect — wrong key, wrong nonce, stale timestamp, tampered
/// transcript — plus the happy path on both accept and reject
/// responses.
@Suite("HandshakeResponseVerifier")
struct HandshakeResponseVerifierTests {
    private static let nonce = Data([
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    ])

    private func makeKeypair() -> (private: Curve25519.Signing.PrivateKey, publicData: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation)
    }

    private func sign(
        using priv: Curve25519.Signing.PrivateKey,
        nonce: Data,
        signedAtUnixNs: Int64,
        ok: Bool,
        reason: String,
    ) -> Data {
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: nonce,
            signedAtUnixNs: signedAtUnixNs,
            ok: ok,
            reason: reason,
        )
        return try! priv.signature(for: transcript)
    }

    private func buildResponse(
        signature: Data,
        echoedNonce: Data,
        signedAtUnixNs: Int64,
        ok: Bool,
        reason: String,
    ) -> Catlaser_App_V1_AuthResponse {
        var response = Catlaser_App_V1_AuthResponse()
        response.ok = ok
        response.reason = reason
        response.nonce = echoedNonce
        response.signature = signature
        response.signedAtUnixNs = signedAtUnixNs
        return response
    }

    // MARK: - Happy paths

    @Test
    func validAcceptResponseVerifies() throws {
        let (priv, pub) = makeKeypair()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(using: priv, nonce: Self.nonce, signedAtUnixNs: signedAt, ok: true, reason: "")
        let response = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        try verifier.verify(
            response: response,
            expectedNonce: Self.nonce,
            now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
        )
    }

    @Test
    func validRejectResponseVerifies() throws {
        // A rejection path (e.g. SKEW_EXCEEDED) is also signed so
        // the app can tell "real device said no" from "impostor
        // said no". Verification must succeed for rejects too.
        let (priv, pub) = makeKeypair()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let reason = "DEVICE_AUTH_SKEW_EXCEEDED"
        let sig = sign(using: priv, nonce: Self.nonce, signedAtUnixNs: signedAt, ok: false, reason: reason)
        let response = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: false,
            reason: reason,
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        try verifier.verify(
            response: response,
            expectedNonce: Self.nonce,
            now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
        )
    }

    // MARK: - Failure modes

    @Test
    func wrongSigningKeyFailsSignatureVerify() throws {
        // The real device's pubkey is in `pub`, but the response is
        // signed with a *different* key. This is the impostor case.
        let (_, pub) = makeKeypair()
        let impostor = Curve25519.Signing.PrivateKey()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(using: impostor, nonce: Self.nonce, signedAtUnixNs: signedAt, ok: true, reason: "")
        let response = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        do {
            try verifier.verify(
                response: response,
                expectedNonce: Self.nonce,
                now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
            )
            Issue.record("expected throw on impostor signature")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSignatureInvalid)
        }
    }

    @Test
    func nonceMismatchIsDetectedBeforeSignature() throws {
        // The attacker replays a captured response. Its `nonce` is
        // whatever the earlier exchange produced; the current
        // exchange has a new nonce. Even if the signature is valid
        // for the OLD nonce, the check fails on the echo.
        let (priv, pub) = makeKeypair()
        let oldNonce = Data(repeating: 0xAA, count: 16)
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(using: priv, nonce: oldNonce, signedAtUnixNs: signedAt, ok: true, reason: "")
        let response = buildResponse(
            signature: sig,
            echoedNonce: oldNonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        do {
            try verifier.verify(
                response: response,
                expectedNonce: Self.nonce,
                now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
            )
            Issue.record("expected throw on nonce mismatch")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeNonceMismatch)
        }
    }

    @Test
    func timestampOutsideSkewWindowRejected() throws {
        // A captured response older than the skew window cannot be
        // accepted even if the attacker somehow steered a nonce
        // collision — the timestamp is in the signed transcript.
        let (priv, pub) = makeKeypair()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(using: priv, nonce: Self.nonce, signedAtUnixNs: signedAt, ok: true, reason: "")
        let response = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        // Clock reads 10 minutes after the signing time (skew is
        // 5 minutes).
        let now = Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000 + 600)
        do {
            try verifier.verify(
                response: response,
                expectedNonce: Self.nonce,
                now: now,
            )
            Issue.record("expected throw on stale signed_at")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSkewExceeded)
        }
    }

    @Test
    func tamperedOkByteFailsSignatureVerify() throws {
        // The device signed `ok=false, reason="..."`. An attacker
        // flips the bool to `true` hoping to trick the app into
        // treating the connection as authorized. The signature is
        // over the transcript that includes the ok byte, so the
        // flip breaks verification.
        let (priv, pub) = makeKeypair()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(
            using: priv,
            nonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: false,
            reason: "DEVICE_AUTH_NOT_AUTHORIZED",
        )
        let tampered = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: true, // flipped
            reason: "DEVICE_AUTH_NOT_AUTHORIZED",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: pub)
        do {
            try verifier.verify(
                response: tampered,
                expectedNonce: Self.nonce,
                now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
            )
            Issue.record("expected throw on flipped ok byte")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSignatureInvalid)
        }
    }

    @Test
    func malformedPublicKeyRejectsAsSignatureInvalid() throws {
        // A 31-byte key cannot be a valid Curve25519 public key.
        // The verifier collapses the load failure into
        // `.handshakeSignatureInvalid` so higher layers don't have
        // to differentiate "bad key" from "bad signature" — both
        // mean the same thing: don't trust this response.
        let (priv, _) = makeKeypair()
        let signedAt: Int64 = 1_800_000_000_000_000_000
        let sig = sign(using: priv, nonce: Self.nonce, signedAtUnixNs: signedAt, ok: true, reason: "")
        let response = buildResponse(
            signature: sig,
            echoedNonce: Self.nonce,
            signedAtUnixNs: signedAt,
            ok: true,
            reason: "",
        )
        let verifier = HandshakeResponseVerifier(devicePublicKey: Data(repeating: 0x42, count: 31))
        do {
            try verifier.verify(
                response: response,
                expectedNonce: Self.nonce,
                now: Date(timeIntervalSince1970: Double(signedAt) / 1_000_000_000),
            )
            Issue.record("expected throw on malformed pubkey")
        } catch let error as DeviceClientError {
            #expect(error == .handshakeSignatureInvalid)
        }
    }

    // MARK: - Transcript cross-stack parity

    @Test
    func transcriptMatchesCanonicalByteLayout() {
        // Exact byte-for-byte parity with the Python
        // `build_auth_response_transcript` helper. If either side
        // ever changes the layout, this test fails loudly rather
        // than letting the two implementations drift silently into
        // mutual incomprehension.
        let nonce = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                          0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00])
        let transcript = HandshakeResponseVerifier.buildTranscript(
            nonce: nonce,
            signedAtUnixNs: 0x0102_0304_0506_0708,
            ok: true,
            reason: "ok",
        )
        // Expected bytes (hex):
        //   "catlaser-auth-response-v1\0"                  (26 bytes)
        //   + nonce (16 bytes)
        //   + 0x0807060504030201                           (u64 LE)
        //   + 0x01                                         (ok byte)
        //   + "ok"                                         (2 bytes)
        var expected = Data()
        expected.append(contentsOf: HandshakeResponseVerifier.transcriptDomain)
        expected.append(nonce)
        expected.append(contentsOf: [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        expected.append(0x01)
        expected.append(contentsOf: "ok".utf8)
        #expect(transcript == expected)
    }
}
