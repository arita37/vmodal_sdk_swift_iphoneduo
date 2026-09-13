import Foundation
import VModalSDK

func waitForIndex(_ client: VModalClient, jobID: String) async throws {
    let deadline = ContinuousClock.now + .seconds(600)
    while ContinuousClock.now < deadline {
        let value = try await client.indexes.indexStatus(jobID)
        if ["completed", "success", "done"].contains(value.status.lowercased()) { return }
        if ["failed", "error"].contains(value.status.lowercased()) {
            throw APIError("index job failed", details: value.raw["error_code"]?.stringValue)
        }
        try await Task.sleep(for: .seconds(5))
    }
    throw TransportError("index polling deadline exceeded")
}

let env = ProcessInfo.processInfo.environment
var client: VModalClient?
var group = ""
var primary: Error?
var stage = "configuration"
var primaryStage = ""
do {
    guard let path = env["VMODAL_LIVE_FILE"], !path.isEmpty else {
        throw ValidationError("VMODAL_LIVE_FILE is required for the explicit live gate")
    }
    let value = try await VModalClient.fromEnvironment(env, resolveIdentity: false)
    client = value
    let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
    group = "sdk_swift_live_\(stamp)"
    stage = "auth.me"
    let profile = try await value.auth.me()
    guard profile.userID?.isEmpty == false else { throw AuthenticationError("auth/me returned no user_id") }
    let source = try UploadSource(fileURL: URL(fileURLWithPath: path))
    stage = "collections.videoUpload"
    _ = try await value.collections.videoUpload(
        source, collectionName: group, subCollectionName: "astream"
    ).result
    stage = "indexes.createIndex"
    let job = try await value.indexes.createIndex(.init(
        mode: "vid_file", groupName: group, streamName: "astream",
        indexType: "vid_img_emb", modality: "vid_img_emb"
    ))
    stage = "indexes.waitForIndex"
    try await waitForIndex(value, jobID: job.jobID)
    stage = "collections.listGroups"
    let groups = try await value.collections.listGroups(mode: "vid_file")
    guard let version = groups.findGroup(group, mode: "vid_file")?.latestLancedbVersion else {
        throw MalformedResponseError("indexed collection has no advertised LanceDB version")
    }
    stage = "searches.searchVideo"
    _ = try await value.searches.searchVideo(.init(
        queryText: "dummy video", groupName: group, streamName: "astream",
        searchSources: ["image"], versionLancedb: version
    ))
    print("live lifecycle passed: auth, signed upload, index, advertised version, search")
} catch {
    primary = error
    primaryStage = stage
}
if let client, !group.isEmpty {
    do {
        stage = "cleanup.delete"
        _ = try await client.collections.delete(groupName: group, mode: "vid_file", confirm: true)
        stage = "cleanup.listGroups"
        let groups = try await client.collections.listGroups(mode: "vid_file")
        if groups.findGroup(group, mode: "vid_file") != nil { throw APIError("live collection still exists after cleanup") }
    } catch {
        if primary == nil {
            primary = error
            primaryStage = stage
        }
    }
}
await client?.close()
if let primary {
    FileHandle.standardError.write(Data("live gate failed; stage=\(primaryStage); reconcile collection=\(group): \(primary)\n".utf8))
    exit(1)
}
