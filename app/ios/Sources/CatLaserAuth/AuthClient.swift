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
        http: any HTTPClient = URLSessionHTTPClient(),
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

    public func exchangeSocial(
        provider: SocialProvider,
        idToken: SocialIDToken,
    ) async throws -> AuthSession {
        let trimmedToken = idToken.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw AuthError.missingIDToken
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

    /// Request a magic-link email for the given address. The device fingerprint
    /// header is stored by the server against the issued token so it can be
    /// compared at link completion.
    public func requestMagicLink(
        email: String,
        callbackURL: String?,
        fingerprintHeader: String,
    ) async throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEmail(trimmedEmail) else {
            throw AuthError.invalidEmail
        }
        guard !fingerprintHeader.isEmpty else {
            throw AuthError.fingerprintCaptureFailed("empty fingerprint header")
        }

        let payload = MagicLinkRequestBody(email: trimmedEmail, callbackURL: callbackURL)
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
        request.setValue(fingerprintHeader, forHTTPHeaderField: DeviceFingerprintEncoder.headerName)

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

    /// Complete a magic-link sign-in. Sends the token together with the same
    /// device fingerprint captured at request time; the server rejects with
    /// 403 `DEVICE_MISMATCH` if they disagree.
    public func completeMagicLink(
        token: String,
        fingerprintHeader: String,
    ) async throws -> AuthSession {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw AuthError.invalidMagicLink("empty token")
        }
        guard !fingerprintHeader.isEmpty else {
            throw AuthError.fingerprintCaptureFailed("empty fingerprint header")
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
        request.setValue(fingerprintHeader, forHTTPHeaderField: DeviceFingerprintEncoder.headerName)

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

    public func signOut(session: AuthSession) async throws {
        var request = URLRequest(url: config.signOutURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
