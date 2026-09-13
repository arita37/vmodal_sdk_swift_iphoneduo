import XCTest
@testable import VModalSDK

final class TransportTests: XCTestCase {
    func testDeclaredAndObservedLimits() async throws {
        let declaredToken = CancellationToken()
        do {
            _ = try await readBounded(fakeResponse(declaredLength: 99), limit: 10, idleTimeout: .seconds(1), cancellation: declaredToken)
            XCTFail("expected declared limit")
        } catch { XCTAssertTrue(error is ResponseTooLargeError) }

        let response = VModalResponse(statusCode: 200, declaredLength: -1, body: AsyncThrowingStream { stream in
            stream.yield(Data(repeating: 1, count: 6)); stream.yield(Data(repeating: 2, count: 6)); stream.finish()
        })
        let observedToken = CancellationToken()
        do {
            _ = try await readBounded(response, limit: 10, idleTimeout: .seconds(1), cancellation: observedToken)
            XCTFail("expected observed limit")
        } catch { XCTAssertTrue(error is ResponseTooLargeError) }
    }

    func testGETRetriesAndPOSTDoesNot() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key", maxRetries: 1)
        let getFake = FakeTransport([.success(fakeResponse(503)), .success(fakeResponse(body: #"{"ok":true}"#))])
        let getHTTP = HTTPClient(config: cfg, transport: getFake)
        let value = try await getHTTP.requestJSON("GET", "/health")
        XCTAssertEqual(value["ok"], .bool(true))
        let getCount = await getFake.requests.count
        XCTAssertEqual(getCount, 2)

        let postFake = FakeTransport([.failure(TransportError("timeout")), .success(fakeResponse())])
        let postHTTP = HTTPClient(config: cfg, transport: postFake)
        do { _ = try await postHTTP.requestJSON("POST", "/search"); XCTFail("expected failure") }
        catch { XCTAssertTrue(error is TransportError) }
        let postCount = await postFake.requests.count
        XCTAssertEqual(postCount, 1)
    }

    func testGatewayHeadersReadRotatedKeyAndExcludeIdentity() async throws {
        let provider = try MutableAPIKeyProvider("one")
        let cfg = try SDKConfig(
            baseURL: URL(string: "http://localhost:4099")!, userID: "must-not-leak",
            tenantID: "tenant", email: "x@example.com", apiKeyProvider: provider
        )
        let http = HTTPClient(config: cfg, transport: FakeTransport([]))
        let first = try await http.headers()
        XCTAssertEqual(first, ["Authorization": "Bearer one"])
        try await provider.rotate("two")
        let second = try await http.headers()
        XCTAssertEqual(second, ["Authorization": "Bearer two"])
    }

    func testStatusMappingAndBodyRedaction() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let fake = FakeTransport([.success(fakeResponse(422, body: #"{"detail":"bad /Users/name/private.txt"}"#))])
        do {
            _ = try await HTTPClient(config: cfg, transport: fake).requestJSON("POST", "/search")
            XCTFail("expected validation")
        } catch let error as ValidationError {
            XCTAssertEqual(error.statusCode, 422)
            XCTAssertFalse(String(describing: error.body).contains("/Users/name"))
        }
    }

    func testCancellationWins() async throws {
        let token = CancellationToken()
        await token.cancel()
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        do {
            _ = try await HTTPClient(config: cfg, transport: FakeTransport([])).requestJSON("GET", "/health", cancellation: token)
            XCTFail("expected cancellation")
        } catch { XCTAssertTrue(error is OperationCanceledError) }
    }
}
