import Foundation
import VModalSDK

func waitForCCTVIndex(_ client: VModalClient, jobID: String) async throws {
    let deadline = ContinuousClock.now + .seconds(600)
    while ContinuousClock.now < deadline {
        let value = try await client.indexes.indexStatus(jobID)
        if ["completed", "success", "done"].contains(value.status.lowercased()) { return }
        if ["failed", "error"].contains(value.status.lowercased()) { throw APIError("CCTV index job failed") }
        try await Task.sleep(for: .seconds(5))
    }
    throw TransportError("CCTV index polling deadline exceeded")
}

let env = ProcessInfo.processInfo.environment
var client: VModalClient?
var group = ""
var primary: Error?
do {
    guard let path = env["VMODAL_CCTV_FILE"], !path.isEmpty else {
        throw ValidationError("VMODAL_CCTV_FILE is required for the explicit CCTV live gate")
    }
    let value = try await VModalClient.fromEnvironment(env, resolveIdentity: false)
    client = value
    let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
    group = "sdk_swift_cctv_\(stamp)"
    let videoName = "camera_\(stamp).mp4"
    let file = URL(fileURLWithPath: path)
    let part = try VModalFilePart.file(fieldName: "file", url: file)
    let uploaded = try await value.collections.uploadFile(
        part, groupName: group, streamName: "astream",
        videoFilename: videoName, metadataText: "swift cctv entrance",
        metadataTags: ["swift-cctv", "entrance", "tag3"],
        startDatetimeUser: "2026-07-30T09:15:00+09:00"
    )
    guard uploaded.raw["video_filename"]?.stringValue == videoName,
          uploaded.raw["start_datetime_user"]?.stringValue == "2026-07-30T09:15:00+09:00",
          uploaded.raw["start_ts_unix_user_ms"]?.intValue == 1_785_370_500_000,
          uploaded.raw["timestamp_source"]?.stringValue == "user"
    else { throw MalformedResponseError("CCTV response fields do not match the request") }
    let job = try await value.indexes.createIndex(.init(
        mode: "vid_file", groupName: group, streamName: "astream",
        indexType: "vid_img_emb", modality: "vid_img_emb"
    ))
    try await waitForCCTVIndex(value, jobID: job.jobID)
    let groups = try await value.collections.listGroups(mode: "vid_file")
    guard let version = groups.findGroup(group, mode: "vid_file")?.latestLancedbVersion else {
        throw MalformedResponseError("indexed CCTV collection has no advertised LanceDB version")
    }
    let result = try await value.searches.searchVideo(.init(
        queryText: "pink and cyan diagonal stripes",
        mode: "vid_file", groupName: group, streamName: "astream", searchSources: ["image"],
        startDate: "2026-07-30T00:15:00Z", endDate: "2026-07-30T00:16:00Z",
        limit: 1_000, versionLancedb: version
    ))
    guard result.cntActual > 0 else { throw APIError("CCTV absolute-time search returned no hits") }
    print("live CCTV upload, index, advertised version, and absolute-time search passed")
} catch {
    primary = error
}
if let client, !group.isEmpty {
    do { _ = try await client.collections.delete(groupName: group, mode: "vid_file", confirm: true) }
    catch { if primary == nil { primary = error } }
}
await client?.close()
if let primary {
    FileHandle.standardError.write(Data("CCTV live gate failed; reconcile collection=\(group): \(primary)\n".utf8))
    exit(1)
}
