import Foundation

public protocol JSONBackedResponse: Sendable {
    var raw: [String: JSONValue] { get }
}

private func string(_ raw: [String: JSONValue], _ key: String, default value: String = "") -> String {
    raw[key]?.stringValue ?? value
}

private func int(_ raw: [String: JSONValue], _ key: String) -> Int { raw[key]?.intValue ?? 0 }
private func double(_ raw: [String: JSONValue], _ key: String) -> Double { raw[key]?.doubleValue ?? 0 }
private func bool(_ raw: [String: JSONValue], _ key: String) -> Bool {
    guard case .bool(let value) = raw[key] else { return false }
    return value
}
private func objects(_ value: JSONValue?) -> [[String: JSONValue]] {
    guard case .array(let values) = value else { return [] }
    return values.compactMap(\.objectValue)
}
private func strings(_ value: JSONValue?) -> [String] {
    guard case .array(let values) = value else { return [] }
    return values.map { $0.stringValue ?? String(describing: $0) }
}

public struct SearchResultItem: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct FolderUploadItem: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct CollectionAsset: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct IndexationJobItem: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct AdminUserStatItem: JSONBackedResponse { public let raw: [String: JSONValue] }

public struct GroupItem: JSONBackedResponse {
    public let raw: [String: JSONValue]
    public let userID: String
    public let mode: String
    public let groupName: String
    public let videoGroup: String
    public let modalityTypes: [String]
    public let lancedbVersions: [String]
    public let lastUpdated: String?

    public init(raw: [String: JSONValue]) {
        self.raw = raw
        userID = string(raw, "user_id")
        mode = string(raw, "mode")
        groupName = string(raw, "group_name")
        videoGroup = string(raw, "video_group")
        modalityTypes = strings(raw["modality_types"])
        lancedbVersions = strings(raw["lancedb_versions"])
        lastUpdated = raw["last_updated"]?.stringValue
    }

    public var latestLancedbVersion: Int? {
        lancedbVersions.compactMap { value -> Int? in
            let clean = value.lowercased()
            guard clean.first == "v" else { return nil }
            return Int(clean.dropFirst())
        }.max()
    }
}

public struct SearchRequest: Sendable {
    public let queryText: String
    public let queryMetadata: [String: JSONValue]?
    public let queryMetadataText: String?
    public let imageQuery: String?
    public let mode: String
    public let groupName: String
    public let streamName: String
    public let searchSources: [String]
    public let searchCombineMode: String
    public let startDate: String?
    public let endDate: String?
    public let offset: Int
    public let limit: Int
    public let textEmbScoreMin: Double
    public let imageEmbScoreMin: Double
    public let versionLancedb: Int?

    public init(
        queryText: String = "", queryMetadata: [String: JSONValue]? = nil,
        queryMetadataText: String? = nil, imageQuery: String? = nil,
        mode: String = "vid_file", groupName: String = "agroup", streamName: String = "astream",
        searchSources: [String] = ["ocr", "asr", "image"], searchCombineMode: String = "union",
        startDate: String? = nil, endDate: String? = nil, offset: Int = 0, limit: Int = 50,
        textEmbScoreMin: Double = 0.90, imageEmbScoreMin: Double = 1.5,
        versionLancedb: Int? = nil
    ) {
        self.queryText = queryText; self.queryMetadata = queryMetadata
        self.queryMetadataText = queryMetadataText; self.imageQuery = imageQuery
        self.mode = mode; self.groupName = groupName; self.streamName = streamName
        self.searchSources = searchSources; self.searchCombineMode = searchCombineMode
        self.startDate = startDate; self.endDate = endDate; self.offset = offset; self.limit = limit
        self.textEmbScoreMin = textEmbScoreMin; self.imageEmbScoreMin = imageEmbScoreMin
        self.versionLancedb = versionLancedb
    }

    public func validate() throws {
        if queryMetadata != nil && queryMetadataText != nil {
            throw ValidationError("query_metadata map and query_metadata_text cannot both be set")
        }
        if queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (imageQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (queryMetadataText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw ValidationError("query_text, image_query, or query_metadata_text is required")
        }
        if mode == "vid_file" {
            guard (startDate == nil) == (endDate == nil) else {
                throw ValidationError("vid_file absolute time filtering requires both start_date and end_date")
            }
            try validateSearchDate(startDate, field: "start_date")
            try validateSearchDate(endDate, field: "end_date")
        }
    }

    public func json() -> JSONValue {
        var value: [String: JSONValue] = [
            "query_text": .string(queryText), "mode": .string(mode), "group_name": .string(groupName),
            "stream_name": .string(streamName), "search_sources": .array(searchSources.map(JSONValue.string)),
            "search_combine_mode": .string(searchCombineMode), "offset": .int(Int64(offset)),
            "limit": .int(Int64(limit)), "text_emb_score_min": .double(textEmbScoreMin),
            "image_emb_score_min": .double(imageEmbScoreMin),
        ]
        if let queryMetadataText { value["query_metadata"] = .string(queryMetadataText) }
        else if let queryMetadata { value["query_metadata"] = .object(queryMetadata) }
        if let imageQuery { value["image_query"] = .string(imageQuery) }
        if let startDate { value["start_date"] = .string(startDate) }
        if let endDate { value["end_date"] = .string(endDate) }
        if let versionLancedb { value["version_lancedb"] = .int(Int64(versionLancedb)) }
        return .object(value)
    }
}

private func validateSearchDate(_ value: String?, field: String) throws {
    guard let value else { return }
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard format.date(from: clean) != nil else { throw ValidationError("\(field) must be a valid ISO-8601 value") }
        return
    }
    guard clean.range(of: #"(?:[zZ]|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
          ISO8601DateFormatter().date(from: clean) != nil else {
        throw ValidationError("\(field) must include Z or an explicit UTC offset for vid_file")
    }
}

public struct DeleteCollectionRequest: Sendable {
    public let groupName: String; public let mode: String; public let scope: String
    public let dryRun: Bool; public let confirm: Bool
    public init(groupName: String, mode: String, scope: String = "all", dryRun: Bool = false, confirm: Bool = false) {
        self.groupName = groupName; self.mode = mode; self.scope = scope; self.dryRun = dryRun; self.confirm = confirm
    }
    public func validate() throws { try required(groupName, "group_name"); try required(mode, "mode") }
    public func json() -> JSONValue { .object(["group_name": .string(groupName), "mode": .string(mode), "scope": .string(scope), "dry_run": .bool(dryRun), "confirm": .bool(confirm)]) }
}

public struct CollectionAddAssetsRequest: Sendable {
    public let collectionID: String; public let assetIDs: [String]; public let mode: String
    public let groupName: String; public let streamName: String
    public init(collectionID: String, assetIDs: [String], mode: String, groupName: String, streamName: String = "astream") {
        self.collectionID = collectionID; self.assetIDs = assetIDs; self.mode = mode; self.groupName = groupName; self.streamName = streamName
    }
    public func validate() throws {
        try required(collectionID, "collection_id")
        guard !assetIDs.isEmpty else { throw ValidationError("asset_ids is required") }
        try required(mode, "mode"); try required(groupName, "group_name")
    }
    public func json() -> JSONValue { .object(["collection_id": .string(collectionID), "asset_ids": .array(assetIDs.map(JSONValue.string)), "mode": .string(mode), "group_name": .string(groupName), "stream_name": .string(streamName)]) }
}

public struct IndexationSubmitRequest: Sendable {
    public let mode: String; public let groupName: String; public let streamName: String?
    public let indexType: String?; public let modality: String?; public let insertMode: String
    public let createIndex: Bool; public let version: String; public let startDate: String?
    public let endDate: String?; public let embeddingModel: String?; public let reProcess: Bool; public let dryRun: Bool
    public init(
        mode: String, groupName: String, streamName: String? = nil, indexType: String? = nil,
        modality: String? = nil, insertMode: String = "append", createIndex: Bool = true,
        version: String = "new_version", startDate: String? = nil, endDate: String? = nil,
        embeddingModel: String? = nil, reProcess: Bool = false, dryRun: Bool = false
    ) {
        self.mode = mode; self.groupName = groupName; self.streamName = streamName; self.indexType = indexType
        self.modality = modality; self.insertMode = insertMode; self.createIndex = createIndex; self.version = version
        self.startDate = startDate; self.endDate = endDate; self.embeddingModel = embeddingModel
        self.reProcess = reProcess; self.dryRun = dryRun
    }
    public func validate() throws { try required(mode, "mode"); try required(groupName, "group_name") }
    public func json() -> JSONValue {
        var value: [String: JSONValue] = ["mode": .string(mode), "group_name": .string(groupName), "insert_mode": .string(insertMode), "create_index": .bool(createIndex), "version": .string(version), "re_process": .bool(reProcess), "dry_run": .bool(dryRun)]
        value.add("stream_name", streamName); value.add("index_type", indexType); value.add("modality", modality)
        value.add("start_date", startDate); value.add("end_date", endDate); value.add("embedding_model", embeddingModel)
        return .object(value)
    }
}

public struct IndexationDeleteRequest: Sendable {
    public let mode: String; public let groupName: String; public let version: String
    public let modality: String?; public let dryRun: Bool; public let confirm: Bool
    public init(mode: String, groupName: String, version: String, modality: String? = nil, dryRun: Bool = false, confirm: Bool = false) {
        self.mode = mode; self.groupName = groupName; self.version = version; self.modality = modality; self.dryRun = dryRun; self.confirm = confirm
    }
    public func validate() throws { try required(mode, "mode"); try required(groupName, "group_name"); try required(version, "version") }
    public func json() -> JSONValue {
        var value: [String: JSONValue] = ["mode": .string(mode), "group_name": .string(groupName), "version": .string(version), "dry_run": .bool(dryRun), "confirm": .bool(confirm)]
        value.add("modality", modality); return .object(value)
    }
}

public struct ImageRecord: Sendable {
    public let mode: String; public let groupName: String; public let streamName: String
    public let filename: String; public let frameID: String; public let userid: String?
    public init(mode: String = "", groupName: String = "", streamName: String = "astream", filename: String = "", frameID: String = "", userid: String? = nil) {
        self.mode = mode; self.groupName = groupName; self.streamName = streamName; self.filename = filename; self.frameID = frameID; self.userid = userid
    }
    public func json(includeIdentity: Bool = true) -> JSONValue {
        var value: [String: JSONValue] = ["mode": .string(mode), "group_name": .string(groupName), "stream_name": .string(streamName), "filename": .string(filename), "frame_id": .string(frameID)]
        if includeIdentity { value.add("userid", userid) }; return .object(value)
    }
}

public struct ImageURLRecord: Sendable {
    public let mode: String; public let groupName: String; public let modality: String
    public let streamName: String; public let filename: String; public let tsUnix13digits: String?
    public init(mode: String = "", groupName: String = "", modality: String = "", streamName: String = "astream", filename: String = "", tsUnix13digits: String? = nil) {
        self.mode = mode; self.groupName = groupName; self.modality = modality; self.streamName = streamName; self.filename = filename; self.tsUnix13digits = tsUnix13digits
    }
    public func json() -> JSONValue {
        var value: [String: JSONValue] = ["mode": .string(mode), "group_name": .string(groupName), "modality": .string(modality), "stream_name": .string(streamName), "filename": .string(filename)]
        value.add("ts_unix_13digits", tsUnix13digits); return .object(value)
    }
}

private func required(_ value: String, _ field: String) throws {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("\(field) is required") }
}
private extension Dictionary where Key == String, Value == JSONValue {
    mutating func add(_ key: String, _ value: String?) { if let value { self[key] = .string(value) } }
}

public struct HealthResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let status: String; public let timestamp: String?
    public let version: String?; public let pythonVersion: String?; public let dependencies: JSONValue?
    public init(raw: [String: JSONValue]) { self.raw = raw; status = string(raw, "status"); timestamp = raw["timestamp"]?.stringValue; version = raw["version"]?.stringValue; pythonVersion = raw["python_version"]?.stringValue; dependencies = raw["dependencies"] }
}
public struct SearchResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let data: [JSONValue]; public let cntActual: Int; public let cntTotal: Int; public let executionTimeMs: Double
    public init(raw: [String: JSONValue]) { self.raw = raw; if case .array(let value) = raw["data"] { data = value } else { data = [] }; cntActual = int(raw, "cnt_actual"); cntTotal = int(raw, "cnt_total"); executionTimeMs = double(raw, "execution_time_ms") }
}
public struct GroupsResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let data: [GroupItem]; public let total: Int; public let executionTimeMs: Double
    public init(raw: [String: JSONValue]) { self.raw = raw; data = objects(raw["data"]).map(GroupItem.init); total = int(raw, "total"); executionTimeMs = double(raw, "execution_time_ms") }
    public func findGroup(_ name: String, mode: String? = nil) -> GroupItem? { data.first { $0.groupName.trimmingCharacters(in: .whitespacesAndNewlines) == name.trimmingCharacters(in: .whitespacesAndNewlines) && (mode == nil || $0.mode == mode) } }
}
public struct ExternalUploadSignedURLResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let userID: String; public let expiresIn: Int; public let key: String; public let url: String; public let method: String
    public init(raw: [String: JSONValue]) { self.raw = raw; userID = string(raw, "user_id"); expiresIn = int(raw, "expires_in"); key = string(raw, "key"); url = string(raw, "url"); method = string(raw, "method", default: "PUT") }
}
public struct MultipartPart: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let partNumber: Int; public let etag: String; public let sizeBytes: Int
    public init(raw: [String: JSONValue]) { self.raw = raw; partNumber = int(raw, "part_number"); etag = string(raw, "etag"); sizeBytes = int(raw, "size_bytes") }
}
public struct MultipartSignedPart: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let partNumber: Int; public let url: String; public let method: String; public let headers: [String: String]
    public init(raw: [String: JSONValue]) { self.raw = raw; partNumber = int(raw, "part_number"); url = string(raw, "url"); method = string(raw, "method", default: "PUT"); headers = raw["headers"]?.objectValue?.mapValues { $0.stringValue ?? String(describing: $0) } ?? [:] }
}
public struct MultipartCreateResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let requestID: String; public let uploadID: String; public let key: String; public let sizeBytes: Int; public let partSizeBytes: Int; public let partCount: Int; public let status: String
    public init(raw: [String: JSONValue]) { self.raw = raw; requestID = string(raw, "request_id"); uploadID = string(raw, "upload_id"); key = string(raw, "key"); sizeBytes = int(raw, "size_bytes"); partSizeBytes = int(raw, "part_size_bytes"); partCount = int(raw, "part_count"); status = string(raw, "status", default: "created") }
}
public struct MultipartSignResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let parts: [MultipartSignedPart]; public let expiresIn: Int
    public init(raw: [String: JSONValue]) { self.raw = raw; parts = objects(raw["parts"]).map(MultipartSignedPart.init); expiresIn = int(raw, "expires_in") }
}
public struct MultipartStatusResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let status: String; public let parts: [MultipartPart]; public let etag: String; public let sizeBytes: Int
    public init(raw: [String: JSONValue]) { self.raw = raw; status = string(raw, "status", default: "uploading"); parts = objects(raw["parts"]).map(MultipartPart.init); etag = string(raw, "etag"); sizeBytes = int(raw, "size_bytes") }
}
public struct MultipartCompleteResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let status: String; public let key: String; public let etag: String; public let sizeBytes: Int; public let alreadyCompleted: Bool
    public init(raw: [String: JSONValue]) { self.raw = raw; status = string(raw, "status", default: "completed"); key = string(raw, "key"); etag = string(raw, "etag"); sizeBytes = int(raw, "size_bytes"); alreadyCompleted = bool(raw, "already_completed") }
}

public struct UploadResponse: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct FolderUploadResponse: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct MetadataParquetUploadResponse: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct CollectionDescriptionUpdateResponse: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct DeleteCollectionResponse: JSONBackedResponse { public let raw: [String: JSONValue] }
public struct CollectionAddAssetsResponse: JSONBackedResponse { public let raw: [String: JSONValue] }

public struct VideoUploadResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]
    public let userID, key, url, method, filename, uploadStrategy, uploadID, etag, destPath: String
    public let videoFilename, startDatetimeUser, timestampSource, filePath, sourceFilePath: String
    public let sizeBytes, statusCode, partSizeBytes, partCount, partsUploaded, attemptCount: Int
    public let startTsUnixUserMs, sourceSizeBytes: Int
    public let uploaded, resumed, reduceSize, temporaryFileDeleted, temporaryFileReused: Bool
    public init(raw: [String: JSONValue]) {
        self.raw = raw; userID = string(raw, "user_id"); key = string(raw, "key"); url = string(raw, "url")
        method = string(raw, "method", default: "PUT"); filename = string(raw, "filename"); sizeBytes = int(raw, "size_bytes")
        statusCode = int(raw, "status_code"); uploaded = bool(raw, "uploaded"); uploadStrategy = string(raw, "upload_strategy", default: "single")
        uploadID = string(raw, "upload_id"); etag = string(raw, "etag"); partSizeBytes = int(raw, "part_size_bytes"); partCount = int(raw, "part_count")
        partsUploaded = int(raw, "parts_uploaded"); resumed = bool(raw, "resumed"); attemptCount = int(raw, "attempt_count"); destPath = string(raw, "dest_path")
        videoFilename = string(raw, "video_filename"); startDatetimeUser = string(raw, "start_datetime_user"); startTsUnixUserMs = int(raw, "start_ts_unix_user_ms")
        timestampSource = string(raw, "timestamp_source"); reduceSize = bool(raw, "reduce_size"); filePath = string(raw, "filepath_local")
        sourceFilePath = string(raw, "source_filepath_local"); sourceSizeBytes = int(raw, "source_size_bytes")
        temporaryFileDeleted = bool(raw, "temporary_file_deleted"); temporaryFileReused = bool(raw, "temporary_file_reused")
    }
}
public struct VideoUploadBulkResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let data: [VideoUploadResponse]; public let total: Int
    public init(raw: [String: JSONValue]) { self.raw = raw; data = objects(raw["data"]).map(VideoUploadResponse.init); total = int(raw, "total") }
}
public struct IndexationJobsListResponse: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let data: [JSONValue]; public let total: Int
    public init(raw: [String: JSONValue]) { self.raw = raw; if case .array(let value) = raw["data"] { data = value } else { data = [] }; total = int(raw, "total") }
}
public struct IndexationSubmitResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let jobID: String; public let status: String; public init(raw: [String: JSONValue]) { self.raw = raw; jobID = string(raw, "job_id"); status = string(raw, "status") } }
public struct IndexationStatusResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let jobID: String; public let status: String; public init(raw: [String: JSONValue]) { self.raw = raw; jobID = string(raw, "job_id"); status = string(raw, "status") } }
public struct IndexationDeleteResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let status: String; public init(raw: [String: JSONValue]) { self.raw = raw; status = string(raw, "status") } }
public struct AdminUserStatsResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let data: [JSONValue]; public let total: Int; public init(raw: [String: JSONValue]) { self.raw = raw; if case .array(let value) = raw["data"] { data = value } else { data = [] }; total = int(raw, "total") } }
public struct UserProfile: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let userID, email, name, tenantID: String?; public let roles: [JSONValue]; public let permissions: [String]; public let type: String
    public init(raw: [String: JSONValue]) { self.raw = raw; userID = raw["user_id"]?.stringValue; email = raw["email"]?.stringValue; name = raw["name"]?.stringValue; tenantID = raw["tenant_id"]?.stringValue; if case .array(let value) = raw["roles"] { roles = value } else { roles = [] }; permissions = strings(raw["permissions"]); type = string(raw, "type", default: "user") }
}
public struct UsageUserDetail: JSONBackedResponse {
    public let raw: [String: JSONValue]; public let date, userID: String; public let total: Int; public let endpoints: [String: Int]
    public init(raw: [String: JSONValue]) { self.raw = raw; date = string(raw, "date"); userID = string(raw, "user_id"); total = int(raw, "total"); endpoints = raw["endpoints"]?.objectValue?.mapValues { $0.intValue ?? 0 } ?? [:] }
}
public struct CacheStats: JSONBackedResponse { public let raw: [String: JSONValue]; public let apiKeyCacheSize, rateLimiterBuckets: Int; public let config: [String: JSONValue]; public init(raw: [String: JSONValue]) { self.raw = raw; apiKeyCacheSize = int(raw, "apikey_cache_size"); rateLimiterBuckets = int(raw, "rate_limiter_buckets"); config = raw["config"]?.objectValue ?? [:] } }
public struct PresignedUploadResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let userID: String; public let expiresIn: Int; public let key, url, method: String; public init(raw: [String: JSONValue]) { self.raw = raw; userID = string(raw, "user_id"); expiresIn = int(raw, "expires_in"); key = string(raw, "key"); url = string(raw, "url"); method = string(raw, "method", default: "PUT") } }
public struct PresignedFolderItem: JSONBackedResponse { public let raw: [String: JSONValue]; public let filename, key, url, method: String; public init(raw: [String: JSONValue]) { self.raw = raw; filename = string(raw, "filename"); key = string(raw, "key"); url = string(raw, "url"); method = string(raw, "method", default: "PUT") } }
public struct PresignedFolderResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let userID: String; public let expiresIn: Int; public let files: [PresignedFolderItem]; public init(raw: [String: JSONValue]) { self.raw = raw; userID = string(raw, "user_id"); expiresIn = int(raw, "expires_in"); files = objects(raw["files"]).map(PresignedFolderItem.init) } }
public struct ImageURLResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let found: Bool; public let urlPreSigned, fullPath: String; public let expireSec: Int; public let error: String; public init(raw: [String: JSONValue]) { self.raw = raw; found = bool(raw, "found"); urlPreSigned = string(raw, "url_pre_signed"); fullPath = string(raw, "full_path"); expireSec = int(raw, "expire_sec"); error = string(raw, "error") } }
public struct ImageURLBulkResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let records: [[String: JSONValue]]; public init(raw: [String: JSONValue]) { self.raw = raw; records = objects(raw["records"]) } }
public struct ImageGetBulkResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let records: [[String: JSONValue]]; public init(raw: [String: JSONValue]) { self.raw = raw; records = objects(raw["records"]) } }
public struct ImageResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let found: Bool; public let imgBase64: String; public init(raw: [String: JSONValue]) { self.raw = raw; found = bool(raw, "found"); imgBase64 = string(raw, "img_base64") } }
public struct FullPathImageResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let found: Bool; public let imgBase64, fullpath: String; public init(raw: [String: JSONValue]) { self.raw = raw; found = bool(raw, "found"); imgBase64 = string(raw, "img_base64"); fullpath = string(raw, "fullpath") } }
public struct ImageBulkResponse: JSONBackedResponse { public let raw: [String: JSONValue]; public let records: [[String: JSONValue]]; public init(raw: [String: JSONValue]) { self.raw = raw; records = objects(raw["records"]) } }
