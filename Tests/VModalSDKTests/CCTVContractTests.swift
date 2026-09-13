import XCTest
@testable import VModalSDK

final class CCTVContractTests: XCTestCase {
    func testDirectUploadPreservesEmptyMetadataAndOrderedTags() async throws {
        let fake = FakeTransport([.success(fakeResponse())])
        let cfg = try SDKConfig(baseURL: URL(string: "http://localhost:4099")!, token: "key")
        let part = try VModalFilePart(fieldName: "file", filename: "x.mp4", length: 1, contentType: "video/mp4") {
            AsyncThrowingStream { value in value.yield(Data([1])); value.finish() }
        }
        _ = try await CollectionsResource(http: HTTPClient(config: cfg, transport: fake)).uploadFile(part, groupName: "p__c", metadataText: "", metadataTags: ["one", "two"], reProcess: true)
        let request = await fake.requests[0]
        XCTAssertEqual(request.formFields.filter { $0.name == "metadata_text" }.map(\.value), [""])
        XCTAssertEqual(request.formFields.filter { $0.name == "metadata_tags" }.compactMap(\.value), ["one", "two"])
        XCTAssertEqual(request.formFields.first { $0.name == "re_process" }?.value, "true")
    }

    func testCCTVFilenameAndTimestampValidation() {
        XCTAssertThrowsError(try validateCCTVUpload(mode: "img_file", sourceFilename: "x.mp4", videoFilename: "x.mp4", startDatetimeUser: nil))
        XCTAssertThrowsError(try validateCCTVUpload(mode: "vid_file", sourceFilename: "x.mp4", videoFilename: "x.mov", startDatetimeUser: nil))
        XCTAssertThrowsError(try validateCCTVUpload(mode: "vid_file", sourceFilename: "x.mp4", videoFilename: nil, startDatetimeUser: "2026-01-01T00:00:00"))
        XCTAssertNoThrow(try validateCCTVUpload(mode: "vid_file", sourceFilename: "x.mp4", videoFilename: nil, startDatetimeUser: "2026-01-01T00:00:00Z"))
        XCTAssertEqual(cctvFilename(sourceFilename: "x.mp4", videoFilename: nil, startDatetimeUser: "2026-01-01T00:00:00Z"), "x.mp4")
    }
}
