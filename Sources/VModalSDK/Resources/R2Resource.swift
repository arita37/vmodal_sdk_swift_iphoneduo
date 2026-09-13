import Foundation

public struct R2Resource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }
    public func presignUploadFile(mode: String, groupName: String, streamName: String, modality: String, filename: String, expiresIn: Int = 900, cancellation: CancellationToken? = nil) async throws -> PresignedUploadResponse {
        let query = [("mode", mode), ("group_name", groupName), ("stream_name", streamName), ("modality", modality), ("filename", filename), ("expires_in", String(expiresIn))].map(URLQueryItem.init)
        return PresignedUploadResponse(raw: try await http.requestUsersJSON("GET", Routes.usersFull(Routes.r2UploadFile), queryItems: query, cancellation: cancellation))
    }
    public func presignUploadFolderVideo(mode: String, groupName: String, streamName: String, filenames: [String], expiresIn: Int = 900, cancellation: CancellationToken? = nil) async throws -> PresignedFolderResponse {
        let json: JSONValue = .object(["mode": .string(mode), "group_name": .string(groupName), "stream_name": .string(streamName), "filenames": .array(filenames.map(JSONValue.string)), "expires_in": .int(Int64(expiresIn))])
        return PresignedFolderResponse(raw: try await http.requestUsersJSON("POST", Routes.usersFull(Routes.r2UploadFolderVideo), json: json, cancellation: cancellation))
    }
}
