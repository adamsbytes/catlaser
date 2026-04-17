import Foundation
import Testing

@testable import CatLaserAuth

@Suite("HTTPResponse")
struct HTTPResponseTests {
    @Test
    func caseInsensitiveHeaderLookup() {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "SET-AUTH-TOKEN": "abc"],
            body: Data(),
        )
        #expect(response.header("content-type") == "application/json")
        #expect(response.header("Content-Type") == "application/json")
        #expect(response.header("set-auth-token") == "abc")
        #expect(response.header("X-Missing") == nil)
    }

    @Test
    func headerAbsent() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data())
        #expect(response.header("anything") == nil)
    }
}
