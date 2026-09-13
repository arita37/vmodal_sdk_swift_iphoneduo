import XCTest
@testable import VModalSDK

final class ConfigRoutesTests: XCTestCase {
    func testRouteFixtureExactness() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "routes_contract", withExtension: "json"))
        let fixture = try JSONDecoder().decode([RouteSpec].self, from: Data(contentsOf: url))
        XCTAssertEqual(Routes.specs.sorted(by: { $0.name < $1.name }), fixture)
    }

    func testPrefixesAndPathSegmentEscaping() throws {
        XCTAssertEqual(try Routes.full(Routes.health), "/api/external/v1/health")
        XCTAssertEqual(try Routes.usersFull(Routes.authMe), "/api/v1/auth/me")
        XCTAssertThrowsError(try Routes.full("https://example.com/bad"))
        let path = try Routes.replacingPathSegment(
            in: "/collection/{collection_id}/assets/create",
            placeholder: "collection_id",
            value: "a/b"
        )
        XCTAssertEqual(path, "/collection/a%2Fb/assets/create")
    }
}
