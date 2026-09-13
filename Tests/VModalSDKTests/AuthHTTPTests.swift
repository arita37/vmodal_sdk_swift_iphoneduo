import XCTest
@testable import VModalSDK

final class AuthHTTPTests: XCTestCase {
    func testGatewayRotationAndIdentityIsolation() async throws {
        let provider = try MutableAPIKeyProvider("first")
        let config = try SDKConfig(
            baseURL: URL(string: "http://localhost:4099")!, userID: "private-user",
            tenantID: "private-tenant", email: "private@example.com", apiKeyProvider: provider
        )
        let http = HTTPClient(config: config, transport: FakeTransport([]))
        let first = try await http.headers()
        try await provider.rotate("second")
        let second = try await http.headers()
        XCTAssertEqual(first["Authorization"], "Bearer first")
        XCTAssertEqual(second["Authorization"], "Bearer second")
        XCTAssertNil(second["X-User-Id"])
        XCTAssertNil(second["X-Tenant-Id"])
        XCTAssertNil(second["X-User-Email"])
    }

    func testAuthenticationAndValidationStatusTypes() async throws {
        let config = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let fake = FakeTransport([
            .success(fakeResponse(401, body: #"{"detail":"expired"}"#)),
            .success(fakeResponse(422, body: #"{"detail":"invalid"}"#)),
        ])
        let http = HTTPClient(config: config, transport: fake)
        do { _ = try await http.requestJSON("GET", "/health"); XCTFail("expected auth error") }
        catch { XCTAssertTrue(error is AuthenticationError) }
        do { _ = try await http.requestJSON("POST", "/search"); XCTFail("expected validation error") }
        catch { XCTAssertTrue(error is ValidationError) }
    }
}
