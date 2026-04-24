import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AuthClient: Sendable {
    public static let bearerHeader = "set-auth-token"

    public let config: AuthConfig
    private let http: any HTTPClient
    private let clock: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        config: AuthConfig,
        http: any HTTPClient,
    ) {
        self.init(config: config, http: http, clock: { Date() })
    }

    init(
        config: AuthConfig,
        http: any HTTPClient,
        clock: @escaping @Sendable () -> Date,
    ) {
        self.config = config
        self.http = http
        self.clock = clock
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Exchange a provider-issued ID token for a bearer session. The
    /// `attestationHeader` binds the exchange to the SE key that generated
    /// the sign-in nonce: the attestation's `bnd` encodes `"sis:<rawNonce>"`
    /// and the server cross-references this against the `idToken.nonce`
    /// field in the request body and the `nonce` claim in the signed ID
    /// token. A captured `(idToken, nonce, attestation)` triple cannot be
    /// replayed from a different device — the SE private key never
    /// leaves the device that minted the signature — and cannot be
    /// replayed on the same device either, because the nonce is
    /// single-use at the server.
    public func exchangeSocial(
        provider: SocialProvider,
        idToken: SocialIDToken,
        attestationHeader: String,
    ) async throws -> AuthSession {
        let trimmedToken = idToken.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw AuthError.missingIDToken
        }
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }
        let payload = SocialSignInRequest(
            provider: provider,
            idToken: SocialIDToken(
                token: trimmedToken,
                rawNonce: idToken.rawNonce,
                accessToken: idToken.accessToken,
            ),
        )
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw AuthError.malformedResponse("request encode failure: \(error.localizedDescription)")
        }

        var request = URLRequest(url: config.socialSignInURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)

        let response = try await http.send(request)

        switch response.statusCode {
        case 200 ..< 300:
            return try parseSocialSuccess(response, provider: provider)
        case 400, 401, 403:
            throw AuthError.credentialInvalid(extractMessage(from: response))
        default:
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    /// Request a magic-link email for the given address. The attestation
    /// header is stored by the server against the issued token so it can
    /// be compared at link completion. The callback URL (where the email
    /// points) is derived from `AuthConfig.magicLinkCallbackURL` — a
    /// Universal-Link-only path distinct from the API verify endpoint.
    public func requestMagicLink(
        email: String,
        attestationHeader: String,
    ) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEmail(trimmedEmail) else {
            throw AuthError.invalidEmail
        }
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }

        let payload = MagicLinkRequestBody(
            email: trimmedEmail,
            callbackURL: config.magicLinkCallbackURL.absoluteString,
        )
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw AuthError.malformedResponse("request encode failure: \(error.localizedDescription)")
        }

        var request = URLRequest(url: config.magicLinkRequestURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)

        let response = try await http.send(request)

        switch response.statusCode {
        case 200 ..< 300:
            return
        case 400:
            throw AuthError.invalidEmail
        case 401, 403:
            throw AuthError.credentialInvalid(extractMessage(from: response))
        default:
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    /// Complete a magic-link sign-in. Sends the token together with a
    /// fresh attestation whose `fph` and `pk` must byte-match the values
    /// recorded at request time and whose `sig` must verify under the
    /// same SE key. Server rejects with 403 `DEVICE_MISMATCH` if any of
    /// those three conditions fail.
    public func completeMagicLink(
        token: String,
        attestationHeader: String,
    ) async throws -> AuthSession {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw AuthError.invalidMagicLink("empty token")
        }
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }

        guard var components = URLComponents(url: config.magicLinkVerifyURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidMagicLink("unparseable verify URL")
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: trimmedToken))
        components.queryItems = items
        guard let url = components.url else {
            throw AuthError.invalidMagicLink("unparseable verify URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)

        let response = try await http.send(request)

        switch response.statusCode {
        case 200 ..< 300:
            return try parseVerifySuccess(response)
        case 400:
            throw AuthError.invalidMagicLink(extractMessage(from: response))
        case 401:
            throw AuthError.credentialInvalid(extractMessage(from: response))
        case 403:
            throw AuthError.invalidMagicLink(extractMessage(from: response))
        case 410:
            throw AuthError.invalidMagicLink(extractMessage(from: response) ?? "magic link expired")
        default:
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    /// Complete a magic-link sign-in via the 6-digit backup code shown
    /// beneath the tap link in the email. Same attestation binding as
    /// ``completeMagicLink(token:attestationHeader:)`` — `ver:<code>`
    /// where the URL path uses `ver:<token>` — and the server enforces
    /// the stored `(fph, pk)` match against the row captured at request
    /// time, so a captured code cannot be redeemed from a different
    /// device. Redeeming either path makes the other inert.
    public func completeMagicLinkByCode(
        code: String,
        attestationHeader: String,
    ) async throws -> AuthSession {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw AuthError.invalidMagicLink("empty backup code")
        }
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }

        let payload = MagicLinkVerifyByCodeRequestBody(code: trimmedCode)
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw AuthError.malformedResponse("request encode failure: \(error.localizedDescription)")
        }

        var request = URLRequest(url: config.magicLinkVerifyByCodeURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)

        let response = try await http.send(request)

        switch response.statusCode {
        case 200 ..< 300:
            return try parseVerifySuccess(response)
        case 400:
            throw AuthError.invalidMagicLink(extractMessage(from: response))
        case 401:
            // Server maps INVALID_CODE / DEVICE_MISMATCH /
            // ATTESTATION_BINDING_MISMATCH / ATTESTATION_REQUIRED all to
            // 401 so no oracle distinguishes "wrong device" from "wrong
            // code" from "exhausted". We surface the same
            // `invalidMagicLink` shape the URL path uses on 401; the
            // SignInStrings mapper renders the human copy.
            throw AuthError.invalidMagicLink(extractMessage(from: response))
        case 403:
            throw AuthError.invalidMagicLink(extractMessage(from: response))
        case 410:
            throw AuthError.invalidMagicLink(extractMessage(from: response) ?? "backup code expired")
        default:
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    private static let emailPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
            options: [],
        )
    }()

    private static func isPlausibleEmail(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 320, let regex = emailPattern else { return false }
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return regex.firstMatch(in: candidate, options: [], range: range) != nil
    }

    /// Invalidate the server-side session. Carries the same v3
    /// `x-device-attestation` header as the other authenticated endpoints,
    /// with `bnd = "out:<unix_seconds>"` so a captured magic-link-request
    /// header cannot be replayed to sign a user out, and a captured
    /// sign-out header is replay-bounded by the server's skew window.
    /// A leaked bearer token alone is insufficient to revoke the
    /// session — the attacker also needs a signature from the original
    /// Secure-Enclave key.
    public func signOut(
        session: AuthSession,
        attestationHeader: String,
    ) async throws {
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }
        var request = URLRequest(url: config.signOutURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)
        let response = try await http.send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    /// Permanently delete the user account on the coordination server.
    /// The server revokes every device ACL grant for this user and
    /// drops the ``user`` row in one transaction; cascade FKs clear
    /// sessions, accounts, session-attestation rows, and per-session
    /// idempotency records.
    ///
    /// Like ``signOut``, the call carries the bearer token plus a
    /// dedicated ``x-device-attestation`` header signed with the
    /// ``del:<unix_seconds>`` binding tag. A captured sign-out or
    /// protected-route attestation cannot be replayed here because
    /// the server-side gate enforces a tag match, and an empty /
    /// missing attestation header is refused locally before the
    /// request hits the wire so a misconfigured call never spends
    /// a signing operation on an unusable round-trip.
    public func deleteAccount(
        session: AuthSession,
        attestationHeader: String,
    ) async throws {
        guard !attestationHeader.isEmpty else {
            throw AuthError.attestationFailed("empty attestation header")
        }
        var request = URLRequest(url: config.deleteAccountURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(attestationHeader, forHTTPHeaderField: DeviceAttestationEncoder.headerName)
        let response = try await http.send(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
    }

    private func parseSocialSuccess(
        _ response: HTTPResponse,
        provider: SocialProvider,
    ) throws -> AuthSession {
        guard let bearer = response.header(Self.bearerHeader)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bearer.isEmpty
        else {
            throw AuthError.missingBearerToken
        }
        let decoded: SocialSignInResponse
        do {
            decoded = try decoder.decode(SocialSignInResponse.self, from: response.body)
        } catch {
            throw AuthError.malformedResponse(error.localizedDescription)
        }
        return AuthSession(
            bearerToken: bearer,
            user: decoded.user,
            provider: AuthProvider(social: provider),
            establishedAt: clock(),
        )
    }

    private func parseVerifySuccess(_ response: HTTPResponse) throws -> AuthSession {
        guard let bearer = response.header(Self.bearerHeader)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bearer.isEmpty
        else {
            throw AuthError.missingBearerToken
        }
        let decoded: MagicLinkVerifyResponse
        do {
            decoded = try decoder.decode(MagicLinkVerifyResponse.self, from: response.body)
        } catch {
            throw AuthError.malformedResponse(error.localizedDescription)
        }
        return AuthSession(
            bearerToken: bearer,
            user: decoded.user,
            provider: .magicLink,
            establishedAt: clock(),
        )
    }

    private func extractMessage(from response: HTTPResponse) -> String? {
        guard !response.body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let code = object["code"] as? String, !code.isEmpty {
                return code
            }
        }
        if let text = String(data: response.body, encoding: .utf8),
           !text.isEmpty,
           text.count <= 512
        {
            return text
        }
        return nil
    }
}
