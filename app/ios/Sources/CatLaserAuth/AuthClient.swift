import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AuthClient: Sendable {
    public static let bearerHeader = "set-auth-token"

    private let config: AuthConfig
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
            return try parseSuccess(response, provider: provider)
        case 400, 401, 403:
            throw AuthError.credentialInvalid(extractMessage(from: response))
        default:
            throw AuthError.serverError(
                status: response.statusCode,
                message: extractMessage(from: response),
            )
        }
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

    private func parseSuccess(
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
            provider: provider,
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
