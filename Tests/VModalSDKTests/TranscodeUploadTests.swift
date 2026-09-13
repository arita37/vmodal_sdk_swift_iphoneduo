import XCTest
@testable import VModalSDK

final class TranscodeUploadTests: XCTestCase {
    func testProducedTempDeletedAndOriginalRetained() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmodal-transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("source.mp4"); let reduced = dir.appendingPathComponent("source.reduced.mp4")
        try Data(repeating: 1, count: 10).write(to: original); try Data(repeating: 2, count: 3).write(to: reduced)
        let api = FakeTransport([.success(fakeResponse(body: #"{"url":"http://localhost:9090/u","key":"k"}"#)), .success(fakeResponse(body: #"{"dest_path":"done"}"#))])
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let source = try UploadSource(fileURL: original)
        let response = try await CollectionsResource(http: HTTPClient(config: cfg, transport: api), signedUploadTransport: FakeSignedTransport()).videoUpload(source, collectionName: "p__c", subCollectionName: "s", options: .init(transcoder: FakeTranscoder(output: reduced), startDatetimeUser: "2026-01-01T00:00:00Z")).result
        XCTAssertTrue(response.reduceSize); XCTAssertEqual(response.sizeBytes, 3); XCTAssertEqual(response.sourceSizeBytes, 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: reduced.path))
        let last = await api.requests.last
        let query = URLComponents(url: try XCTUnwrap(last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "video_filename" }?.value, "source.mp4")
        XCTAssertEqual(query.first { $0.name == "filename" }?.value, "source.reduced.mp4")
    }

    func testStreamSourceRejectsRealTranscoderBeforeNetwork() async throws {
        let source = try UploadSource(filename: "x.mp4", length: 1, opener: { AsyncThrowingStream { value in value.yield(Data([1])); value.finish() } })
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let fake = FakeTransport([])
        do { _ = try await CollectionsResource(http: HTTPClient(config: cfg, transport: fake)).videoUpload(source, collectionName: "p__c", subCollectionName: "s", options: .init(transcoder: FakeTranscoder(output: URL(fileURLWithPath: "/tmp/no")))).result; XCTFail("expected validation") }
        catch { XCTAssertTrue(error is ValidationError) }
        let count = await fake.requests.count; XCTAssertEqual(count, 0)
    }
}

private actor FakeTranscoder: VideoTranscoder {
    nonisolated let isPassthrough = false
    let output: URL
    init(output: URL) { self.output = output }
    func reduce(_ input: URL) async throws -> TranscodeResult { TranscodeResult(output: output) }
}
