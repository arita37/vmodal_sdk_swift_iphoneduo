import XCTest
@testable import VModalSDK

final class ScopedAPITests: XCTestCase {
    func testConfigurationDoesNotReadCredential() async throws {
        let provider = CountingKeyProvider()
        _ = try VModal.configure(projectID: "food_app", apiKeyProvider: provider, baseURL: URL(string: "http://localhost:4099"))
        let count = await provider.count
        XCTAssertEqual(count, 0)
    }

    func testScopeMappingIsImmutable() throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let project = try VModal.fromClient(projectID: "food_app", client: VModalClient(config: cfg, transport: FakeTransport([]), signedUploadTransport: FakeSignedTransport()))
        let scope = try project.scope(collectionName: "user_123", streamName: "favorites")
        XCTAssertEqual(scope.projectID, "food_app")
        XCTAssertEqual(scope.collectionName, "user_123")
        XCTAssertEqual(scope.streamName, "favorites")
    }

    func testListCollectionsOrderAndFirstDuplicate() async throws {
        let body = #"{"data":[{"group_name":"app__b"},{"group_name":"other__x"},{"group_name":"app__a"},{"group_name":"app__b"}]}"#
        let fake = FakeTransport([.success(fakeResponse(body: body))])
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let project = try VModal.fromClient(projectID: "app", client: VModalClient(config: cfg, transport: fake, signedUploadTransport: FakeSignedTransport()))
        let collections = try await project.listCollections()
        XCTAssertEqual(collections, ["b", "a"])
    }

    func testCloseOwnershipIsIdempotent() async throws {
        let control = FakeTransport([]); let signed = FakeSignedTransport()
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let project = try VModal.fromClient(projectID: "app", client: VModalClient(config: cfg, transport: control, signedUploadTransport: signed))
        await project.close(); await project.close()
        let controlCount = await control.closeCount
        let signedCount = await signed.closeCount
        XCTAssertEqual(controlCount, 1)
        XCTAssertEqual(signedCount, 1)
    }
}

private actor CountingKeyProvider: APIKeyProvider {
    private(set) var count = 0
    func current() async throws -> String { count += 1; return "key" }
}
