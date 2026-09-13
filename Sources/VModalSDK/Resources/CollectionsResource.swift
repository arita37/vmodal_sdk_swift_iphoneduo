import Foundation

public struct CollectionsResource: Sendable {
    let http: HTTPClient
    let signedUploads: any SignedUploadTransport
    public init(http: HTTPClient, signedUploadTransport: (any SignedUploadTransport)? = nil) {
        self.http = http
        signedUploads = signedUploadTransport ?? URLSessionSignedUploadTransport()
    }

    public func listGroups(mode: String? = nil, cancellation: CancellationToken? = nil) async throws -> GroupsResponse {
        let query = mode.map { [URLQueryItem(name: "mode", value: $0)] } ?? []
        return GroupsResponse(raw: try await http.requestJSON(
            "GET", Routes.full(Routes.groups), queryItems: query, cancellation: cancellation
        ))
    }

    public func uploadFile(
        _ part: VModalFilePart, groupName: String = "", mode: String = "vid_file",
        streamName: String = "astream", description: String = "", tag: [String] = [],
        videoFilename: String? = nil, metadataText: String? = nil,
        metadataTags: [String]? = nil, startDatetimeUser: String? = nil,
        reProcess: Bool = false, cancellation: CancellationToken? = nil
    ) async throws -> UploadResponse {
        try validateCCTVUpload(mode: mode, sourceFilename: part.filename, videoFilename: videoFilename, startDatetimeUser: startDatetimeUser)
        let publicName = cctvFilename(sourceFilename: part.filename, videoFilename: videoFilename, startDatetimeUser: startDatetimeUser)
        var form = [
            URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "group_name", value: groupName),
            URLQueryItem(name: "stream_name", value: streamName), URLQueryItem(name: "description", value: description),
        ]
        form += tag.map { URLQueryItem(name: "tag", value: $0) }
        if let publicName { form.append(.init(name: "video_filename", value: publicName)) }
        if let metadataText { form.append(.init(name: "metadata_text", value: metadataText)) }
        if let metadataTags { form += metadataTags.map { .init(name: "metadata_tags", value: $0) } }
        if let startDatetimeUser { form.append(.init(name: "start_datetime_user", value: startDatetimeUser)) }
        form.append(.init(name: "re_process", value: String(reProcess).lowercased()))
        return UploadResponse(raw: try await http.requestJSON(
            "POST", Routes.full(Routes.upload), formFields: form, files: [part], cancellation: cancellation
        ))
    }

    public func uploadFolder() throws -> Never {
        throw FeatureDisabledError("folder upload is disabled on server (cannot scan remote PC/laptop)")
    }

    public func uploadMetadataJSONL(
        _ part: VModalFilePart, mode: String = "img_file", groupName: String = "",
        streamName: String = "", writeMode: String = "append", allowOverlap: Bool = false,
        cancellation: CancellationToken? = nil
    ) async throws -> MetadataParquetUploadResponse {
        var form = [
            URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "group_name", value: groupName),
            URLQueryItem(name: "stream_name", value: streamName), URLQueryItem(name: "write_mode", value: writeMode),
            URLQueryItem(name: "allow_overlap", value: String(allowOverlap).lowercased()),
        ]
        if http.config.mode == .direct, let userID = http.config.userID { form.append(.init(name: "user_id", value: userID)) }
        do {
            return MetadataParquetUploadResponse(raw: try await http.requestJSON(
                "POST", Routes.full(Routes.uploadMetadataJSONL), formFields: form, files: [part], cancellation: cancellation
            ))
        } catch let error as APIError where error.statusCode == 404 {
            return MetadataParquetUploadResponse(raw: try await http.requestJSON(
                "POST", Routes.uploadMetadataItemParquetInternal, formFields: form, files: [part], cancellation: cancellation
            ))
        }
    }

    public func addAssets(
        collectionID: String, assetIDs: [String], mode: String, groupName: String,
        streamName: String = "astream", cancellation: CancellationToken? = nil
    ) async throws -> CollectionAddAssetsResponse {
        let request = CollectionAddAssetsRequest(collectionID: collectionID, assetIDs: assetIDs, mode: mode, groupName: groupName, streamName: streamName)
        try request.validate()
        let path = try Routes.replacingPathSegment(in: Routes.collectionAddAssets, placeholder: "collection_id", value: collectionID)
        return CollectionAddAssetsResponse(raw: try await http.requestJSON(
            "POST", Routes.full(path), json: request.json(), cancellation: cancellation
        ))
    }

    public func updateDescription(
        groupName: String, mode: String, streamName: String, filenameSanitized: String,
        description: String? = nil, tag: [String]? = nil, cancellation: CancellationToken? = nil
    ) async throws -> CollectionDescriptionUpdateResponse {
        var form = [
            URLQueryItem(name: "group_name", value: groupName), URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "stream_name", value: streamName), URLQueryItem(name: "filename_sanitized", value: filenameSanitized),
        ]
        if let description { form.append(.init(name: "description", value: description)) }
        if let tag { form += tag.map { .init(name: "tag", value: $0) } }
        return CollectionDescriptionUpdateResponse(raw: try await http.requestJSON(
            "POST", Routes.full(Routes.collectionDescriptionUpdate), formFields: form, cancellation: cancellation
        ))
    }

    public func delete(
        groupName: String, mode: String, scope: String = "all", dryRun: Bool = false,
        confirm: Bool = false, cancellation: CancellationToken? = nil
    ) async throws -> DeleteCollectionResponse {
        let request = DeleteCollectionRequest(groupName: groupName, mode: mode, scope: scope, dryRun: dryRun, confirm: confirm)
        try request.validate()
        return DeleteCollectionResponse(raw: try await http.requestJSON(
            "DELETE", Routes.full(Routes.collectionDelete), json: request.json(), cancellation: cancellation
        ))
    }

    public func create() throws -> Never { throw FeatureDisabledError("no server endpoint; upload creates collection implicitly") }
    public func edit() throws -> Never { throw FeatureDisabledError("no server endpoint; upload creates collection implicitly") }
    public func autoIndexGet() throws -> Never { throw FeatureDisabledError("collection auto_index is disabled on server") }
    public func autoIndexSet() throws -> Never { throw FeatureDisabledError("collection auto_index is disabled on server") }
}


func validateCCTVUpload(mode: String, sourceFilename: String, videoFilename: String?, startDatetimeUser: String?) throws {
    if videoFilename != nil || startDatetimeUser != nil {
        guard mode == "vid_file" else { throw ValidationError("video_filename and start_datetime_user require vid_file mode") }
    }
    if let name = videoFilename {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("\\") else { throw ValidationError("video_filename must be a bare filename") }
        let sourceExt = URL(fileURLWithPath: sourceFilename).pathExtension
        let publicExt = URL(fileURLWithPath: clean).pathExtension
        if !sourceExt.isEmpty, !publicExt.isEmpty, sourceExt.caseInsensitiveCompare(publicExt) != .orderedSame {
            throw ValidationError("video_filename extension must match source extension")
        }
    }
    if let value = startDatetimeUser {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.range(of: #"(?:[zZ]|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw ValidationError("start_datetime_user must include Z or an explicit UTC offset")
        }
    }
}

func cctvFilename(sourceFilename: String, videoFilename: String?, startDatetimeUser: String?) -> String? {
    videoFilename ?? (startDatetimeUser == nil ? nil : sourceFilename)
}
