import XCTest
@testable import VModalSDK

final class UploadTests: XCTestCase {
    func testExactMemoryRangeAndEarlyEOF() async throws {
        let source = try memorySource(Data("abcdef".utf8), name: "x.mp4")
        var data = Data()
        for try await chunk in try source.open(offset: 2, length: 3) { data.append(chunk) }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "cde")

        let short = try UploadSource(filename: "x.mp4", length: 5, opener: {
            AsyncThrowingStream { value in value.yield(Data("abc".utf8)); value.finish() }
        })
        do { for try await _ in try short.open() {}; XCTFail("expected EOF") }
        catch { XCTAssertTrue(error is TransportError) }
    }

    func testSingleUploadPresignPutFinalizeAndCCTVWire() async throws {
        let signedBody = #"{"url":"http://localhost:9090/put","key":"object-key","method":"PUT"}"#
        let doneBody = #"{"dest_path":"r2/file","video_filename":"public.mp4","start_datetime_user":"2026-01-01T00:00:00Z"}"#
        let control = FakeTransport([.success(fakeResponse(body: signedBody)), .success(fakeResponse(body: doneBody))])
        let signed = FakeSignedTransport()
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let collections = CollectionsResource(http: HTTPClient(config: cfg, transport: control), signedUploadTransport: signed)
        let source = try memorySource(Data("video".utf8), name: "source.mp4")
        let task = collections.videoUpload(source, collectionName: "app__global", subCollectionName: "stream", options: .init(videoFilename: "public.mp4", metadataText: "", metadataTags: ["a", "b"], startDatetimeUser: "2026-01-01T00:00:00Z", reProcess: true))
        let response = try await task.result
        XCTAssertTrue(response.uploaded); XCTAssertEqual(response.videoFilename, "public.mp4")
        let requests = await control.requests
        XCTAssertEqual(requests.count, 2)
        let items = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "metadata_text" }.map(\.value), [""])
        XCTAssertEqual(items.filter { $0.name == "metadata_tags" }.compactMap(\.value), ["a", "b"])
        XCTAssertEqual(items.first { $0.name == "re_process" }?.value, "true")
        let putCount = await signed.puts.count
        XCTAssertEqual(putCount, 1)
    }

    func testSignedHeaderAllowlistRejectsCredential() async throws {
        let source = try memorySource(Data("x".utf8), name: "x.mp4")
        do {
            _ = try await URLSessionSignedUploadTransport().put(source: source, range: nil, url: URL(string: "http://localhost:9090/put")!, headers: ["Authorization": "Bearer secret"], timeout: .seconds(1), cancellation: CancellationToken()) { _ in }
            XCTFail("expected rejection")
        } catch { XCTAssertTrue(error is ValidationError) }
    }

    func testBulkEmptyAndFilenameValidation() async throws {
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let collections = CollectionsResource(http: HTTPClient(config: cfg, transport: FakeTransport([])), signedUploadTransport: FakeSignedTransport())
        let empty = try await collections.videoUploadBulk([], collectionName: "p__c", subCollectionName: "s").result
        XCTAssertEqual(empty.total, 0)
        let source = try memorySource(Data("x".utf8), name: "x.mp4")
        do { _ = try await collections.videoUploadBulk([source, source], collectionName: "p__c", subCollectionName: "s", options: .init(videoFilename: "x.mp4")).result; XCTFail("expected validation") }
        catch { XCTAssertTrue(error is ValidationError) }
    }

    func testProgressSupportsMultipleObservers() async throws {
        let task = UploadTask<Int> { _, emit in
            try await Task.sleep(for: .milliseconds(20))
            await emit(.init(uploadedBytes: 1, totalBytes: 100))
            await emit(.init(uploadedBytes: 100, totalBytes: 100))
            return 7
        }
        let first = Task {
            var values: [Int] = []
            for await item in task.progress { values.append(item.percent) }
            return values
        }
        let second = Task {
            var values: [Int] = []
            for await item in task.progress { values.append(item.percent) }
            return values
        }
        let result = try await task.result
        let firstValues = await first.value
        let secondValues = await second.value
        XCTAssertEqual(result, 7)
        XCTAssertEqual(firstValues.last, 100)
        XCTAssertEqual(secondValues.last, 100)
    }
}

private func memorySource(_ data: Data, name: String) throws -> UploadSource {
    try UploadSource(filename: name, length: Int64(data.count), sourceID: "memory:\(name)", versionTag: "1", opener: {
        AsyncThrowingStream { value in value.yield(data); value.finish() }
    })
}
