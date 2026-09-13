import Foundation

public struct VideoUploadOptions: Sendable {
    public static let maxVideoUploadBytes: Int64 = 100 * 1_024 * 1_024
    public let multipart: Bool
    public let multipartThresholdBytes: Int64
    public let partSizeBytes: Int64
    public let maxConcurrency: Int
    public let maxPartAttempts: Int
    public let partTimeout: Duration
    public let resume: Bool
    public let sessionStore: (any UploadSessionStore)?
    public let adaptiveConditions: UploadConditions?
    public let transcoder: any VideoTranscoder
    public let videoFilename: String?
    public let metadataText: String?
    public let metadataTags: [String]?
    public let startDatetimeUser: String?
    public let reProcess: Bool

    public init(
        multipart: Bool = false, multipartThresholdBytes: Int64 = 100 * 1_024 * 1_024,
        partSizeBytes: Int64 = 64 * 1_024 * 1_024, maxConcurrency: Int = 4,
        maxPartAttempts: Int = 5, partTimeout: Duration = .seconds(300), resume: Bool = true,
        sessionStore: (any UploadSessionStore)? = nil,
        adaptiveConditions: UploadConditions? = nil,
        transcoder: any VideoTranscoder = PassthroughVideoTranscoder(),
        videoFilename: String? = nil, metadataText: String? = nil, metadataTags: [String]? = nil,
        startDatetimeUser: String? = nil, reProcess: Bool = false
    ) {
        self.multipart = multipart; self.multipartThresholdBytes = multipartThresholdBytes
        self.partSizeBytes = partSizeBytes; self.maxConcurrency = maxConcurrency
        self.maxPartAttempts = maxPartAttempts; self.partTimeout = partTimeout; self.resume = resume; self.sessionStore = sessionStore
        self.adaptiveConditions = adaptiveConditions; self.transcoder = transcoder
        self.videoFilename = videoFilename; self.metadataText = metadataText
        self.metadataTags = metadataTags; self.startDatetimeUser = startDatetimeUser; self.reProcess = reProcess
    }

    var store: any UploadSessionStore { sessionStore ?? UploadSessionStores.memory }

    public func resolvedFor(_ size: Int64) throws -> VideoUploadOptions {
        guard multipart, let conditions = adaptiveConditions else { return self }
        let preset = try AdaptiveUploadPolicy.select(size, conditions: conditions)
        return copied(partSizeBytes: preset.partSizeBytes, maxConcurrency: preset.maxConcurrency, maxPartAttempts: preset.maxPartAttempts, partTimeout: preset.partTimeout)
    }

    func copied(
        partSizeBytes: Int64? = nil, maxConcurrency: Int? = nil, maxPartAttempts: Int? = nil,
        partTimeout: Duration? = nil, transcoder: (any VideoTranscoder)? = nil,
        videoFilename: String? = nil
    ) -> VideoUploadOptions {
        VideoUploadOptions(
            multipart: multipart, multipartThresholdBytes: multipartThresholdBytes,
            partSizeBytes: partSizeBytes ?? self.partSizeBytes, maxConcurrency: maxConcurrency ?? self.maxConcurrency,
            maxPartAttempts: maxPartAttempts ?? self.maxPartAttempts, partTimeout: partTimeout ?? self.partTimeout,
            resume: resume, sessionStore: sessionStore, adaptiveConditions: adaptiveConditions,
            transcoder: transcoder ?? self.transcoder, videoFilename: videoFilename ?? self.videoFilename,
            metadataText: metadataText, metadataTags: metadataTags, startDatetimeUser: startDatetimeUser, reProcess: reProcess
        )
    }

    public func validate(size: Int64, mode: String, sourceFilename: String) throws {
        try validateCCTVUpload(mode: mode, sourceFilename: sourceFilename, videoFilename: videoFilename, startDatetimeUser: startDatetimeUser)
        guard size <= Self.maxVideoUploadBytes else { throw ValidationError("video file too large: \(size) bytes exceeds the \(Self.maxVideoUploadBytes) bytes (100 MB) limit") }
        guard multipart else { return }
        guard partSizeBytes >= 5 * 1_024 * 1_024 else { throw ValidationError("part_size_bytes must be at least 5 MiB") }
        guard (1 ... 16).contains(maxConcurrency) else { throw ValidationError("max_concurrency must be in 1..16") }
        guard (1 ... 10).contains(maxPartAttempts) else { throw ValidationError("max_part_attempts must be in 1..10") }
        guard partTimeout > .zero else { throw ValidationError("part_timeout must be positive") }
        guard size > 0 else { throw ValidationError("multipart size must be positive") }
        guard (size + partSizeBytes - 1) / partSizeBytes <= 10_000 else { throw ValidationError("part_size_bytes would create more than 10,000 parts") }
    }
}

public extension CollectionsResource {
    func videoUpload(
        _ source: UploadSource, collectionName: String, subCollectionName: String,
        mode: String = "vid_file", modality: String = "vid_raw", ttl: Int = 12_600,
        options: VideoUploadOptions = .init()
    ) -> UploadTask<VideoUploadResponse> {
        let initial = options
        return UploadTask { cancellation, emit in
            let snapshot = try initial.resolvedFor(source.length)
            try snapshot.validate(size: source.length, mode: mode, sourceFilename: source.filename)
            let permits = UploadPermitPool(snapshot.maxConcurrency)
            if !snapshot.transcoder.isPassthrough {
                return try await transcodeUpload(source, collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: snapshot, cancellation: cancellation, emit: emit, permits: permits)
            }
            if snapshot.multipart {
                do { return try await multipartUpload(source, collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: snapshot, cancellation: cancellation, emit: emit, permits: permits) }
                catch let error as APIError where error.statusCode == 404 { throw FeatureDisabledError("experimental multipart upload is unavailable on this gateway; retry with VideoUploadOptions(multipart: false)") }
            }
            return try await singleUpload(source, collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: snapshot, cancellation: cancellation, emit: emit, permits: permits)
        }
    }

    func videoUploadBulk(
        _ sources: [UploadSource], collectionName: String, subCollectionName: String,
        mode: String = "vid_file", modality: String = "vid_raw", ttl: Int = 12_600,
        options: VideoUploadOptions = .init()
    ) -> UploadTask<VideoUploadBulkResponse> {
        let snapshot = sources
        return UploadTask { cancellation, emit in
            if snapshot.count > 1, options.videoFilename != nil { throw ValidationError("bulk upload cannot share one video_filename across multiple sources") }
            let resolved = try snapshot.map { try options.resolvedFor($0.length) }
            for (index, source) in snapshot.enumerated() { try resolved[index].validate(size: source.length, mode: mode, sourceFilename: source.filename) }
            if options.multipart {
                let keys = snapshot.enumerated().map { UploadContract(source: $0.element, baseURL: http.config.baseURL.absoluteString, userID: http.config.userID ?? "", collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, partSize: resolved[$0.offset].partSizeBytes).key }
                guard Set(keys).count == keys.count else { throw ValidationError("bulk multipart upload contains a duplicate source contract") }
            }
            guard !snapshot.isEmpty else { return VideoUploadBulkResponse(raw: ["data": .array([]), "total": .int(0)]) }
            let permits = UploadPermitPool(resolved.map(\.maxConcurrency).min() ?? options.maxConcurrency)
            let cursor = UploadCursor(count: snapshot.count)
            let total = snapshot.reduce(Int64(0)) { $0 + $1.length }
            let aggregate = AggregateProgress(count: snapshot.count, total: total)
            var rows = Array<VideoUploadResponse?>(repeating: nil, count: snapshot.count)
            try await withThrowingTaskGroup(of: [(Int, VideoUploadResponse)].self) { group in
                for _ in 0 ..< min(options.maxConcurrency, snapshot.count) {
                    group.addTask {
                        var own: [(Int, VideoUploadResponse)] = []
                        while let index = await cursor.next() {
                            try await cancellation.throwIfCanceled()
                            let progress: @Sendable (UploadProgress) async -> Void = { item in
                                if let value = await aggregate.update(index: index, bytes: item.uploadedBytes) { await emit(value) }
                            }
                            let item = resolved[index]
                            let result: VideoUploadResponse
                            if !item.transcoder.isPassthrough { result = try await transcodeUpload(snapshot[index], collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: item, cancellation: cancellation, emit: progress, permits: permits) }
                            else if item.multipart { result = try await multipartUpload(snapshot[index], collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: item, cancellation: cancellation, emit: progress, permits: permits) }
                            else { result = try await singleUpload(snapshot[index], collection: collectionName, stream: subCollectionName, mode: mode, modality: modality, ttl: ttl, options: item, cancellation: cancellation, emit: progress, permits: permits) }
                            own.append((index, result))
                        }
                        return own
                    }
                }
                do { for try await result in group { for (index, value) in result { rows[index] = value } } }
                catch { await cancellation.cancel(); group.cancelAll(); throw error }
            }
            let data = rows.map { $0! }
            return VideoUploadBulkResponse(raw: ["data": .array(data.map { .object($0.raw) }), "total": .int(Int64(data.count))])
        }
    }

    private func singleUpload(
        _ source: UploadSource, collection: String, stream: String, mode: String,
        modality: String, ttl: Int, options: VideoUploadOptions,
        cancellation: CancellationToken, emit: @escaping @Sendable (UploadProgress) async -> Void,
        permits: UploadPermitPool
    ) async throws -> VideoUploadResponse {
        let params = [
            URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "group_name", value: collection),
            URLQueryItem(name: "stream_name", value: stream), URLQueryItem(name: "modality", value: modality),
            URLQueryItem(name: "filename", value: source.filename), URLQueryItem(name: "ttl", value: String(ttl)),
        ]
        let signed: [String: JSONValue]
        do {
            signed = try await http.requestJSON("POST", Routes.full(Routes.externalUploadGetSignedURL), queryItems: params, cancellation: cancellation)
        } catch let error as APIError {
            throw APIError("signed upload URL request failed", statusCode: error.statusCode, body: error.body, details: error.details)
        }
        guard let url = URL(string: signed["url"]?.stringValue ?? ""), url.scheme != nil else { throw ValidationError("signed upload URL is empty or invalid") }
        await permits.acquire(); defer { Task { await permits.release() } }
        let result = try await signedUploads.put(source: source, range: nil, url: url, headers: [:], timeout: options.partTimeout, cancellation: cancellation) { bytes in
            await emit(.init(uploadedBytes: bytes, totalBytes: source.length))
        }
        let done = try await uploadDone(key: signed["key"]?.stringValue ?? "", source: source, collection: collection, stream: stream, mode: mode, modality: modality, options: options, cancellation: cancellation)
        var raw = signed
        raw["filename"] = .string(source.filename); raw["size_bytes"] = .int(source.length)
        raw["status_code"] = .int(Int64(result.statusCode)); raw["uploaded"] = .bool(true)
        raw["upload_strategy"] = .string("single"); raw["etag"] = .string(result.etag)
        raw["part_count"] = .int(1); raw["parts_uploaded"] = .int(1); raw["attempt_count"] = .int(1)
        raw["upload_done"] = .object(done); raw["dest_path"] = done["dest_path"] ?? .string("")
        for key in ["video_filename", "start_datetime_user", "start_ts_unix_user_ms", "timestamp_source"] { if let value = done[key] { raw[key] = value } }
        await emit(.init(uploadedBytes: source.length, totalBytes: source.length))
        return VideoUploadResponse(raw: raw)
    }

    private func transcodeUpload(
        _ source: UploadSource, collection: String, stream: String, mode: String,
        modality: String, ttl: Int, options: VideoUploadOptions,
        cancellation: CancellationToken, emit: @escaping @Sendable (UploadProgress) async -> Void,
        permits: UploadPermitPool
    ) async throws -> VideoUploadResponse {
        guard let input = source.localFile else { throw ValidationError("transcoding requires a file-backed source (UploadSource(fileURL:))") }
        let publicName = cctvFilename(sourceFilename: source.filename, videoFilename: options.videoFilename, startDatetimeUser: options.startDatetimeUser)
        let output = try await options.transcoder.reduce(input)
        let produced = output.output.standardizedFileURL != input.standardizedFileURL
        let temp = try UploadSource(fileURL: output.output, contentType: source.contentType)
        if produced, temp.length <= 0 { throw ValidationError("transcoder produced an empty file") }
        let pass = try options.copied(transcoder: PassthroughVideoTranscoder(), videoFilename: publicName).resolvedFor(temp.length)
        try pass.validate(size: temp.length, mode: mode, sourceFilename: temp.filename)
        let response = pass.multipart
            ? try await multipartUpload(temp, collection: collection, stream: stream, mode: mode, modality: modality, ttl: ttl, options: pass, cancellation: cancellation, emit: emit, permits: permits)
            : try await singleUpload(temp, collection: collection, stream: stream, mode: mode, modality: modality, ttl: ttl, options: pass, cancellation: cancellation, emit: emit, permits: permits)
        if produced { try FileManager.default.removeItem(at: output.output); if FileManager.default.fileExists(atPath: output.output.path) { throw APIError("upload completed but reduced temporary video still exists") } }
        var raw = response.raw; raw["reduce_size"] = .bool(true); raw["filepath_local"] = .string(input.path)
        raw["source_filepath_local"] = .string(input.path); raw["source_size_bytes"] = .int(source.length)
        raw["temporary_file_deleted"] = .bool(produced); raw["temporary_file_reused"] = .bool(output.reused)
        return VideoUploadResponse(raw: raw)
    }

    func uploadDone(key: String, source: UploadSource, collection: String, stream: String, mode: String, modality: String, options: VideoUploadOptions, cancellation: CancellationToken) async throws -> [String: JSONValue] {
        let publicName = cctvFilename(sourceFilename: source.filename, videoFilename: options.videoFilename, startDatetimeUser: options.startDatetimeUser)
        var query = [
            URLQueryItem(name: "key", value: key), URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "group_name", value: collection), URLQueryItem(name: "stream_name", value: stream),
            URLQueryItem(name: "modality", value: modality), URLQueryItem(name: "filename", value: source.filename),
        ]
        if let publicName { query.append(.init(name: "video_filename", value: publicName)) }
        if let metadataText = options.metadataText { query.append(.init(name: "metadata_text", value: metadataText)) }
        if let tags = options.metadataTags { query += tags.map { .init(name: "metadata_tags", value: $0) } }
        if let value = options.startDatetimeUser { query.append(.init(name: "start_datetime_user", value: value)) }
        query.append(.init(name: "re_process", value: String(options.reProcess).lowercased()))
        do {
            return try await http.requestJSON("POST", Routes.full(Routes.externalUploadDone), queryItems: query, cancellation: cancellation)
        } catch let error as APIError {
            throw APIError("upload finalization failed", statusCode: error.statusCode, body: error.body, details: error.details)
        }
    }
}

actor UploadPermitPool {
    private var available: Int; private var waits: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { available = max(1, count) }
    func acquire() async { if available > 0 { available -= 1; return }; await withCheckedContinuation { waits.append($0) } }
    func release() { if waits.isEmpty { available += 1 } else { waits.removeFirst().resume() } }
    func run<T: Sendable>(_ cancellation: CancellationToken, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await cancellation.throwIfCanceled(); await acquire()
        do { try await cancellation.throwIfCanceled(); let value = try await operation(); release(); return value }
        catch { release(); throw error }
    }
}
private actor UploadCursor { let count: Int; var value = 0; init(count: Int) { self.count = count }; func next() -> Int? { guard value < count else { return nil }; defer { value += 1 }; return value } }
private actor AggregateProgress {
    var bytes: [Int64]; var sent: Int64 = 0; let total: Int64
    init(count: Int, total: Int64) { bytes = .init(repeating: 0, count: count); self.total = total }
    func update(index: Int, bytes value: Int64) -> UploadProgress? { let next = max(bytes[index], value); let delta = next - bytes[index]; guard delta > 0 else { return nil }; bytes[index] = next; sent += delta; return .init(uploadedBytes: sent, totalBytes: total) }
}
