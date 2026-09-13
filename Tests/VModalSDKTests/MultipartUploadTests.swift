import CryptoKit
import XCTest
@testable import VModalSDK

final class MultipartUploadTests: XCTestCase {
    func testOrderedContractAndHash() throws {
        let source = try multipartSource(Data("abc".utf8))
        let contract = UploadContract(source: source, baseURL: "https://example.com/api", userID: "", collection: "p__c", stream: "s", mode: "vid_file", modality: "vid_raw", partSize: 5_242_880)
        let expected = #"{"protocol":"vmodal_multipart_v2","base_url":"https://example.com/api","user_id":"","source_id":"memory:test","source_version":"1","filename":"x.mp4","content_type":"application/octet-stream","size_bytes":3,"part_size_bytes":5242880,"mode":"vid_file","group_name":"p__c","stream_name":"s","modality":"vid_raw"}"#
        XCTAssertEqual(String(decoding: contract.orderedJSON, as: UTF8.self), expected)
        XCTAssertEqual(contract.key, SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    func testMultipartCreateUploadCompleteFinalizeAndCheckpointRemoval() async throws {
        let responses = [
            fakeResponse(body: #"{"request_id":"r","upload_id":"u","key":"k","part_count":1,"part_size_bytes":5242880}"#),
            fakeResponse(body: #"{"status":"uploading","parts":[]}"#),
            fakeResponse(body: #"{"parts":[{"part_number":1,"url":"http://localhost:9090/part","headers":{}}]}"#),
            fakeResponse(body: #"{"status":"uploading","parts":[{"part_number":1,"etag":"md5","size_bytes":3}]}"#),
            fakeResponse(body: #"{"etag":"whole"}"#),
            fakeResponse(body: #"{"dest_path":"r2/x.mp4"}"#),
        ].map(Result<VModalResponse, Error>.success)
        let control = FakeTransport(responses); let signed = FakeSignedTransport(); let store = MemoryUploadSessionStore()
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let collections = CollectionsResource(http: HTTPClient(config: cfg, transport: control), signedUploadTransport: signed)
        let source = try multipartSource(Data("abc".utf8))
        let result = try await collections.videoUpload(source, collectionName: "p__c", subCollectionName: "s", options: .init(multipart: true, partSizeBytes: 5_242_880, sessionStore: store)).result
        XCTAssertEqual(result.uploadStrategy, "multipart"); XCTAssertEqual(result.etag, "whole")
        let requests = await control.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "POST", "GET", "POST", "POST"])
        let contract = UploadContract(source: source, baseURL: cfg.baseURL.absoluteString, userID: "", collection: "p__c", stream: "s", mode: "vid_file", modality: "vid_raw", partSize: 5_242_880)
        let removed = try await store.load(contract.key)
        XCTAssertNil(removed)
    }

    func testMalformedCheckpointFailsBeforeNetwork() async throws {
        let source = try multipartSource(Data("abc".utf8)); let store = MemoryUploadSessionStore()
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let contract = UploadContract(source: source, baseURL: cfg.baseURL.absoluteString, userID: "", collection: "p__c", stream: "s", mode: "vid_file", modality: "vid_raw", partSize: 5_242_880)
        try await store.save(contract.key, value: ["version": .int(1)])
        let control = FakeTransport([])
        do {
            _ = try await CollectionsResource(http: HTTPClient(config: cfg, transport: control), signedUploadTransport: FakeSignedTransport()).videoUpload(source, collectionName: "p__c", subCollectionName: "s", options: .init(multipart: true, partSizeBytes: 5_242_880, sessionStore: store)).result
            XCTFail("expected checkpoint rejection")
        } catch let error as APIError { XCTAssertTrue(error.message.contains("checkpoint")) }
        let count = await control.requests.count
        XCTAssertEqual(count, 0)
    }

    func testCheckpointJSONUsesDartFieldOrder() throws {
        let contract: [String: JSONValue] = [
            "protocol": .string("vmodal_multipart_v2"), "base_url": .string("https://example.com"),
            "user_id": .string(""), "source_id": .string("memory:test"), "source_version": .string("1"),
            "filename": .string("x.mp4"), "content_type": .string("video/mp4"), "size_bytes": .int(3),
            "part_size_bytes": .int(5_242_880), "mode": .string("vid_file"), "group_name": .string("p__c"),
            "stream_name": .string("s"), "modality": .string("vid_raw"),
        ]
        let raw: [String: JSONValue] = [
            "version": .int(2), "contract": .object(contract), "request_id": .string("r"),
            "upload_id": .string("u"), "key": .string("k"), "part_count": .int(1),
            "part_size_bytes": .int(5_242_880), "part_md5": .object(["1": .string("abc")]),
        ]
        let expected = #"{"version":2,"contract":{"protocol":"vmodal_multipart_v2","base_url":"https://example.com","user_id":"","source_id":"memory:test","source_version":"1","filename":"x.mp4","content_type":"video/mp4","size_bytes":3,"part_size_bytes":5242880,"mode":"vid_file","group_name":"p__c","stream_name":"s","modality":"vid_raw"},"request_id":"r","upload_id":"u","key":"k","part_count":1,"part_size_bytes":5242880,"part_md5":{"1":"abc"}}"#
        XCTAssertEqual(String(decoding: try checkpointJSON(raw), as: UTF8.self), expected)
    }
}

private func multipartSource(_ data: Data) throws -> UploadSource {
    try UploadSource(filename: "x.mp4", length: Int64(data.count), sourceID: "memory:test", versionTag: "1", opener: {
        AsyncThrowingStream { value in value.yield(data); value.finish() }
    })
}
