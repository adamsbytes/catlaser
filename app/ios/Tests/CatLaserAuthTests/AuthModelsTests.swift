import Foundation
import Testing

@testable import CatLaserAuth

@Suite("Auth models")
struct AuthModelsTests {
    @Test
    func socialProviderRawValues() {
        #expect(SocialProvider.apple.rawValue == "apple")
        #expect(SocialProvider.google.rawValue == "google")
        #expect(SocialProvider.allCases.count == 2)
    }

    @Test
    func signInRequestEncodesApplePayload() throws {
        let request = SocialSignInRequest(
            provider: .apple,
            idToken: SocialIDToken(
                token: "apple.id.token",
                rawNonce: "raw-nonce",
                accessToken: nil,
            ),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "{\"idToken\":{\"nonce\":\"raw-nonce\",\"token\":\"apple.id.token\"},\"provider\":\"apple\"}")
    }

    @Test
    func signInRequestEncodesGooglePayload() throws {
        let request = SocialSignInRequest(
            provider: .google,
            idToken: SocialIDToken(
                token: "google.id.token",
                rawNonce: nil,
                accessToken: "google.access.token",
            ),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "{\"idToken\":{\"accessToken\":\"google.access.token\",\"token\":\"google.id.token\"},\"provider\":\"google\"}")
    }

    @Test
    func signInRequestOmitsNilFields() throws {
        let request = SocialSignInRequest(
            provider: .google,
            idToken: SocialIDToken(token: "t"),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "{\"idToken\":{\"token\":\"t\"},\"provider\":\"google\"}")
    }

    @Test
    func authUserDecodesMinimalServerShape() throws {
        let json = "{\"id\":\"user-1\"}".data(using: .utf8)!
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.id == "user-1")
        #expect(user.email == nil)
        #expect(user.name == nil)
        #expect(user.image == nil)
        #expect(user.emailVerified == false)
    }

    @Test
    func authUserDecodesFullShape() throws {
        let json = """
        {"id":"u","email":"a@b.com","name":"Alice","image":"https://cdn/a.png","emailVerified":true}
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(AuthUser.self, from: json)
        #expect(user.id == "u")
        #expect(user.email == "a@b.com")
        #expect(user.name == "Alice")
        #expect(user.image == "https://cdn/a.png")
        #expect(user.emailVerified == true)
    }

    @Test
    func authUserRequiresID() {
        let json = "{}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AuthUser.self, from: json)
        }
    }

    @Test
    func socialSignInResponseDecodes() throws {
        let json = """
        {"user":{"id":"u","email":"a@b.com","emailVerified":true}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(SocialSignInResponse.self, from: json)
        #expect(response.user.id == "u")
        #expect(response.user.email == "a@b.com")
    }

    @Test
    func authSessionRoundTrips() throws {
        let user = AuthUser(id: "u", email: "a@b.com", name: nil, image: nil, emailVerified: true)
        let session = AuthSession(
            bearerToken: "bearer-token",
            user: user,
            provider: .apple,
            establishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuthSession.self, from: data)
        #expect(decoded == session)
    }

    @Test
    func authSessionRejectsUnknownProvider() throws {
        let json = """
        {"bearerToken":"t","user":{"id":"u","emailVerified":true},"provider":"github","establishedAt":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(AuthSession.self, from: json)
        }
    }

    @Test
    func idTokenEquatability() {
        let a = SocialIDToken(token: "t", rawNonce: "n", accessToken: "a")
        let b = SocialIDToken(token: "t", rawNonce: "n", accessToken: "a")
        let c = SocialIDToken(token: "t", rawNonce: "n", accessToken: "different")
        #expect(a == b)
        #expect(a != c)
    }
}
