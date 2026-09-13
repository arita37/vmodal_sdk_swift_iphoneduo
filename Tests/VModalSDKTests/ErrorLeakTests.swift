import XCTest
@testable import VModalSDK

final class ErrorLeakTests: XCTestCase {
    func testDescriptionsHideBodiesTokensPathsAndSignedQueries() throws {
        let token = "top-secret-token"
        let provider = try MutableAPIKeyProvider(token)
        let config = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, apiKeyProvider: provider)
        let request = VModalRequest(
            method: "PUT", url: URL(string: "https://store.example/file?signature=secret")!,
            headers: ["Authorization": "Bearer \(token)"]
        )
        let error = APIError(statusCode: 500, body: .string("/Users/name/private.mov \(token)"))
        XCTAssertFalse(provider.description.contains(token))
        XCTAssertFalse(config.description.contains(token))
        XCTAssertFalse(request.description.contains(token))
        XCTAssertFalse(request.description.contains("signature"))
        XCTAssertFalse(error.description.contains(token))
        XCTAssertFalse(error.description.contains("/Users/name"))
    }
}
