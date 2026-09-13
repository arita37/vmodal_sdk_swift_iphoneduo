import XCTest
@testable import VModalSDK

final class ResourcesModelsTests: XCTestCase {
    func testSearchEncoderDefaultsAndOmission() throws {
        let request = SearchRequest(queryText: "cat")
        try request.validate()
        let raw = try XCTUnwrap(request.json().objectValue)
        XCTAssertEqual(raw["query_text"], .string("cat"))
        XCTAssertEqual(raw["search_sources"], .array([.string("ocr"), .string("asr"), .string("image")]))
        XCTAssertNil(raw["query_metadata"])
        XCTAssertEqual(raw["text_emb_score_min"], .double(0.9))
    }

    func testSearchMetadataEmptyStringIsPresent() throws {
        let request = SearchRequest(queryMetadataText: "")
        XCTAssertThrowsError(try request.validate())
        XCTAssertEqual(request.json().objectValue?["query_metadata"], .string(""))
    }

    func testDatePairAndOffsetValidation() {
        XCTAssertThrowsError(try SearchRequest(queryText: "x", startDate: "2026-01-01").validate())
        XCTAssertThrowsError(try SearchRequest(queryText: "x", startDate: "2026-01-01T00:00:00", endDate: "2026-01-02T00:00:00Z").validate())
        XCTAssertNoThrow(try SearchRequest(queryText: "x", startDate: "2026-01-01", endDate: "2026-01-02").validate())
    }

    func testNumericCoercionAndUnknownFields() {
        let response = SearchResponse(raw: ["cnt_actual": .string("3"), "execution_time_ms": .string("2.5"), "future": .bool(true)])
        XCTAssertEqual(response.cntActual, 3)
        XCTAssertEqual(response.executionTimeMs, 2.5)
        XCTAssertEqual(response.raw["future"], .bool(true))
    }

    func testImageBulkStripsGatewayIdentity() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let fake = FakeTransport([.success(fakeResponse(body: #"{"records":[]}"#))])
        _ = try await ImagesResource(http: HTTPClient(config: cfg, transport: fake)).getURLBulk([["userid": .string("bad"), "user_id": .string("bad2"), "filename": .string("ok")]])
        let body = await fake.requests.first?.jsonBody?.objectValue?["records"]
        guard case .array(let rows) = body, let row = rows.first?.objectValue else { return XCTFail("missing records") }
        XCTAssertNil(row["userid"]); XCTAssertNil(row["user_id"]); XCTAssertEqual(row["filename"], .string("ok"))
    }

    func testInvalidMutationsMakeZeroCalls() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let fake = FakeTransport([])
        let indexes = IndexesResource(http: HTTPClient(config: cfg, transport: fake))
        do { _ = try await indexes.jobsList(limit: 0); XCTFail("expected validation") } catch { XCTAssertTrue(error is ValidationError) }
        let count = await fake.requests.count
        XCTAssertEqual(count, 0)
    }

    func testImageOutputStreamsIntoCallerOwnedDestination() async throws {
        let response = VModalResponse(statusCode: 200, declaredLength: 6, body: AsyncThrowingStream { stream in
            stream.yield(Data("abc".utf8)); stream.yield(Data("def".utf8)); stream.finish()
        })
        let config = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let output = OutputStream.toMemory()
        output.open()
        try await ImagesResource(http: HTTPClient(config: config, transport: FakeTransport([.success(response)])))
            .writeImageFromURL("https://signed.example/image", to: output)
        let data = output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data
        XCTAssertEqual(data, Data("abcdef".utf8))
        XCTAssertEqual(output.streamStatus, .open)
        output.close()
    }
}
