import XCTest
@testable import VModalSDK

final class FoundationTests: XCTestCase {
    func testJSONValueRoundTripAndCoercion() throws {
        let data = Data(#"{"a":1,"b":2.5,"c":true,"d":[null,"3"]}"#.utf8)
        let object = try JSONValue.decodeObject(data)
        XCTAssertEqual(object["a"]?.intValue, 1)
        XCTAssertEqual(object["b"]?.doubleValue, 2.5)
        XCTAssertEqual(object["d"], .array([.null, .string("3")]))
        XCTAssertThrowsError(try JSONValue.decodeObject(Data("[]".utf8)))
    }

    func testCredentialRotationClearAndPermanentClose() async throws {
        let provider = try MutableAPIKeyProvider(" first ")
        let first = try await provider.current()
        XCTAssertEqual(first, "first")
        try await provider.rotate("second")
        let second = try await provider.current()
        XCTAssertEqual(second, "second")
        await provider.clear()
        do { _ = try await provider.current(); XCTFail("expected unavailable key") }
        catch { XCTAssertTrue(error is AuthenticationError) }
        try await provider.rotate("third")
        await provider.close()
        do { try await provider.rotate("fourth"); XCTFail("expected permanent close") }
        catch { XCTAssertTrue(error is AuthenticationError) }
        XCTAssertFalse(provider.description.contains("first"))
    }

    func testConfigurationNormalizationAndRedaction() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099/")!, token: " secret ")
        XCTAssertEqual(cfg.baseURL.absoluteString, "http://localhost:4099/api/v1/proxy/search_api")
        XCTAssertEqual(cfg.usersAPIBaseURL.absoluteString, "http://localhost:4099")
        let key = try await cfg.currentAPIKey()
        XCTAssertEqual(key, "secret")
        XCTAssertFalse(cfg.description.contains("secret"))
        XCTAssertThrowsError(try SDKConfig(baseURL: URL(string: "http://example.com")!, token: "x"))
        XCTAssertThrowsError(try SDKConfig(baseURL: URL(string: "https://u:p@example.com")!, token: "x"))
    }

    func testEnvironmentPrecedence() async throws {
        let cfg = try SDKConfig.fromEnvironment([
            "VMODAL_ENV": "dev",
            "VMODAL_BASE_URL": "http://localhost:4000",
            "VMODAL_API_TOKEN": "fallback",
            "VMODAL_API_KEY": "preferred",
            "VMODAL_MAX_RETRIES": "3",
        ])
        XCTAssertEqual(cfg.maxRetries, 3)
        let key = try await cfg.currentAPIKey()
        XCTAssertEqual(key, "preferred")
        XCTAssertEqual(cfg.baseURL.path, "/api/v1/proxy/search_api")
    }

    func testContentScopeContract() throws {
        let scope = try ContentScope(projectID: " food_app ", collectionName: "global", streamName: "catalog")
        XCTAssertEqual(scope.backendCollectionName, "food_app__global")
        XCTAssertEqual(try ContentScope.decodeCollection(projectID: "food_app", backendName: "food_app__global"), "global")
        XCTAssertNil(try ContentScope.decodeCollection(projectID: "food_app", backendName: "other__global"))
        XCTAssertThrowsError(try ContentScope(projectID: "bad__id", collectionName: "global", streamName: "catalog"))
        XCTAssertThrowsError(try ContentScope(projectID: "food", collectionName: "bad-name", streamName: "catalog"))
    }

    func testErrorDescriptionDoesNotPrintBody() {
        let error = APIError(statusCode: 500, body: .object(["secret": .string("hidden")]))
        XCTAssertFalse(error.description.contains("hidden"))
        XCTAssertTrue(error.description.contains("status=500"))
    }
}
