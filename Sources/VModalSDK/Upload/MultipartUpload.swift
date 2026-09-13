import CryptoKit
import Foundation

struct UploadContract: Sendable {
    let source: UploadSource; let baseURL, userID, collection, stream, mode, modality: String; let partSize: Int64
    var fields: [String: JSONValue] { [
        "protocol": .string("vmodal_multipart_v2"), "base_url": .string(baseURL), "user_id": .string(userID),
        "source_id": .string(source.sourceID), "source_version": .string(source.versionTag),
        "filename": .string(source.filename), "content_type": .string(source.contentType),
        "size_bytes": .int(source.length), "part_size_bytes": .int(partSize), "mode": .string(mode),
        "group_name": .string(collection), "stream_name": .string(stream), "modality": .string(modality),
    ] }
    var orderedJSON: Data {
        let pairs: [(String, JSONValue)] = [
            ("protocol", .string("vmodal_multipart_v2")), ("base_url", .string(baseURL)), ("user_id", .string(userID)),
            ("source_id", .string(source.sourceID)), ("source_version", .string(source.versionTag)),
            ("filename", .string(source.filename)), ("content_type", .string(source.contentType)),
            ("size_bytes", .int(source.length)), ("part_size_bytes", .int(partSize)), ("mode", .string(mode)),
            ("group_name", .string(collection)), ("stream_name", .string(stream)), ("modality", .string(modality)),
        ]
        return Data(("{" + pairs.map { "\(jsonString($0.0)):\(jsonScalar($0.1))" }.joined(separator: ",") + "}").utf8)
    }
    var key: String { SHA256.hash(data: orderedJSON).map { String(format: "%02x", $0) }.joined() }
}

private struct MultipartSession: Sendable {
    let requestID, uploadID, key: String; let partCount: Int; let partSize: Int64
    var partMD5: [Int: String]
    init(requestID: String, uploadID: String, key: String, partCount: Int, partSize: Int64, partMD5: [Int: String] = [:]) {
        self.requestID = requestID; self.uploadID = uploadID; self.key = key; self.partCount = partCount; self.partSize = partSize; self.partMD5 = partMD5
    }
    init(checkpoint raw: [String: JSONValue], contract: UploadContract) throws {
        guard raw["version"]?.intValue == 2, raw["contract"]?.objectValue == contract.fields else { throw APIError("multipart upload checkpoint is incompatible") }
        requestID = raw["request_id"]?.stringValue ?? ""; uploadID = raw["upload_id"]?.stringValue ?? ""; key = raw["key"]?.stringValue ?? ""
        partCount = raw["part_count"]?.intValue ?? 0; partSize = Int64(raw["part_size_bytes"]?.intValue ?? 0)
        var md5: [Int: String] = [:]
        for (key, value) in raw["part_md5"]?.objectValue ?? [:] {
            guard let number = Int(key), number > 0, let digest = value.stringValue else { throw APIError("multipart upload checkpoint is invalid") }
            md5[number] = digest
        }
        partMD5 = md5
        guard !requestID.isEmpty, !uploadID.isEmpty, !key.isEmpty, partCount > 0, partSize == contract.partSize else { throw APIError("multipart upload checkpoint is invalid") }
    }
    func checkpoint(_ contract: UploadContract) -> [String: JSONValue] { [
        "version": .int(2), "contract": .object(contract.fields), "request_id": .string(requestID),
        "upload_id": .string(uploadID), "key": .string(key), "part_count": .int(Int64(partCount)),
        "part_size_bytes": .int(partSize), "part_md5": .object(partMD5.reduce(into: [:]) { $0[String($1.key)] = .string($1.value) }),
    ] }
}

private struct UploadedPart: Sendable { let number: Int; let etag: String; let size: Int64; let md5: String; let attempts: Int }

extension CollectionsResource {
    func multipartUpload(
        _ source: UploadSource, collection: String, stream: String, mode: String,
        modality: String, ttl: Int, options: VideoUploadOptions,
        cancellation: CancellationToken, emit: @escaping @Sendable (UploadProgress) async -> Void,
        permits: UploadPermitPool
    ) async throws -> VideoUploadResponse {
        let contract = UploadContract(source: source, baseURL: http.config.baseURL.absoluteString, userID: http.config.userID ?? "", collection: collection, stream: stream, mode: mode, modality: modality, partSize: options.partSizeBytes)
        let sessionKey = contract.key; let store = options.store
        var session = try await store.load(sessionKey).map { try MultipartSession(checkpoint: $0, contract: contract) }
        if !options.resume, let known = session {
            _ = try await multipartAbort(known, cancellation: cancellation); try await store.remove(sessionKey); session = nil
        }
        var resumed = session != nil
        if session == nil { session = try await multipartCreate(contract, cancellation: cancellation) }
        var active = session!
        try await store.save(sessionKey, value: active.checkpoint(contract))
        var status: [String: JSONValue]
        do { status = try await multipartStatus(active, cancellation: cancellation) }
        catch let error as APIError where error.statusCode == 404 {
            try await store.remove(sessionKey); active = try await multipartCreate(contract, cancellation: cancellation)
            try await store.save(sessionKey, value: active.checkpoint(contract)); resumed = false
            status = try await multipartStatus(active, cancellation: cancellation)
        }
        if status["status"]?.stringValue == "completed" {
            let etag = status["etag"]?.stringValue ?? ""
            guard status["size_bytes"]?.intValue == Int(source.length), !etag.isEmpty else { throw APIError("completed multipart status does not match local upload contract") }
            let done = try await uploadDone(key: active.key, source: source, collection: collection, stream: stream, mode: mode, modality: modality, options: options, cancellation: cancellation)
            try await store.remove(sessionKey)
            return multipartResponse(source, session: active, etag: etag, resumed: resumed, attempts: 0, done: done)
        }
        let remote = jsonObjects(status["parts"])
        let numbers = remote.map { $0["part_number"]?.intValue ?? 0 }
        guard Set(numbers).count == numbers.count, numbers.allSatisfy({ (1 ... active.partCount).contains($0) }) else { throw APIError("multipart status returned duplicate or out-of-range parts") }
        var valid: [Int: [String: JSONValue]] = [:]
        for part in remote {
            let number = part["part_number"]?.intValue ?? 0; let length = partLength(source.length, active.partSize, number)
            guard part["size_bytes"]?.intValue == Int(length) else { continue }
            let expected: String
            if let saved = active.partMD5[number] { expected = saved }
            else { expected = try await md5Hex(source, offset: Int64(number - 1) * active.partSize, length: length) }
            if (part["etag"]?.stringValue ?? "").lowercased() == expected.lowercased() { valid[number] = part; active.partMD5[number] = expected }
        }
        try await store.save(sessionKey, value: active.checkpoint(contract))
        let progress = MultipartProgress(total: source.length, initial: valid.reduce(0) { $0 + Int64($1.value["size_bytes"]?.intValue ?? 0) })
        if !valid.isEmpty { await emit(await progress.snapshot()) }
        let missing = (1 ... active.partCount).filter { valid[$0] == nil }
        var attempts = 0
        for start in stride(from: 0, to: missing.count, by: max(1, options.maxConcurrency * 2)) {
            let batch = Array(missing[start ..< min(missing.count, start + max(1, options.maxConcurrency * 2))])
            let signed = try await multipartSign(active, numbers: batch, ttl: ttl, cancellation: cancellation)
            let signedRows = jsonObjects(signed["parts"]); let byNumber = Dictionary(uniqueKeysWithValues: signedRows.map { ($0["part_number"]?.intValue ?? 0, $0) })
            guard byNumber.count == batch.count, batch.allSatisfy({ byNumber[$0] != nil }) else { throw APIError("multipart sign response did not match requested parts") }
            let fixed = active
            let uploaded = try await withThrowingTaskGroup(of: UploadedPart.self) { group in
                for number in batch {
                    group.addTask {
                        try await multipartPutOne(source, session: fixed, number: number, signed: byNumber[number]!, ttl: ttl, options: options, cancellation: cancellation, emit: { bytes in
                            if let item = await progress.update(number: number, bytes: bytes) { await emit(item) }
                        }, permits: permits)
                    }
                }
                var values: [UploadedPart] = []; for try await item in group { values.append(item) }; return values
            }
            for part in uploaded { attempts += part.attempts; active.partMD5[part.number] = part.md5; _ = await progress.update(number: part.number, bytes: part.size) }
            try await store.save(sessionKey, value: active.checkpoint(contract))
            await emit(await progress.snapshot())
        }
        status = try await multipartStatus(active, cancellation: cancellation)
        let parts = try multipartFinalParts(active, size: source.length, status: status)
        let completeJSON: JSONValue = .object([
            "request_id": .string(active.requestID), "upload_id": .string(active.uploadID), "key": .string(active.key),
            "size_bytes": .int(source.length), "parts": .array(parts.map { .object(["part_number": .int(Int64($0.number)), "etag": .string($0.etag)]) }),
        ])
        let complete = try await http.requestJSON("POST", Routes.full(Routes.externalUploadMultipartComplete), json: completeJSON, cancellation: cancellation)
        let etag = complete["etag"]?.stringValue ?? ""; guard !etag.isEmpty else { throw APIError("multipart complete response returned no ETag") }
        let done = try await uploadDone(key: active.key, source: source, collection: collection, stream: stream, mode: mode, modality: modality, options: options, cancellation: cancellation)
        try await store.remove(sessionKey); await emit(.init(uploadedBytes: source.length, totalBytes: source.length))
        return multipartResponse(source, session: active, etag: etag, resumed: resumed, attempts: attempts, done: done)
    }

    private func multipartCreate(_ contract: UploadContract, cancellation: CancellationToken) async throws -> MultipartSession {
        let requestID = "\(Int64(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString.prefix(8))"
        let raw = try await http.requestJSON("POST", Routes.full(Routes.externalUploadMultipartCreate), json: .object([
            "request_id": .string(requestID), "mode": .string(contract.mode), "group_name": .string(contract.collection),
            "stream_name": .string(contract.stream), "modality": .string(contract.modality), "filename": .string(contract.source.filename),
            "content_type": .string(contract.source.contentType), "size_bytes": .int(contract.source.length), "part_size_bytes": .int(contract.partSize),
        ]), cancellation: cancellation)
        let session = MultipartSession(requestID: raw["request_id"]?.stringValue ?? requestID, uploadID: raw["upload_id"]?.stringValue ?? "", key: raw["key"]?.stringValue ?? "", partCount: raw["part_count"]?.intValue ?? 0, partSize: Int64(raw["part_size_bytes"]?.intValue ?? 0))
        guard !session.uploadID.isEmpty, !session.key.isEmpty, session.partCount == partCount(contract.source.length, contract.partSize), session.partSize == contract.partSize else { throw APIError("multipart create response does not match local upload contract") }
        return session
    }
    private func multipartStatus(_ session: MultipartSession, cancellation: CancellationToken) async throws -> [String: JSONValue] { try await http.requestJSON("GET", Routes.full(Routes.externalUploadMultipartStatus), queryItems: sessionQuery(session), cancellation: cancellation) }
    private func multipartSign(_ session: MultipartSession, numbers: [Int], ttl: Int, cancellation: CancellationToken) async throws -> [String: JSONValue] { try await http.requestJSON("POST", Routes.full(Routes.externalUploadMultipartSignParts), json: .object(["request_id": .string(session.requestID), "upload_id": .string(session.uploadID), "key": .string(session.key), "part_numbers": .array(numbers.map { .int(Int64($0)) }), "ttl": .int(Int64(ttl))]), cancellation: cancellation) }
    private func multipartAbort(_ session: MultipartSession, cancellation: CancellationToken) async throws -> [String: JSONValue] { try await http.requestJSON("POST", Routes.full(Routes.externalUploadMultipartAbort), json: .object(["request_id": .string(session.requestID), "upload_id": .string(session.uploadID), "key": .string(session.key)]), cancellation: cancellation) }

    private func multipartPutOne(_ source: UploadSource, session: MultipartSession, number: Int, signed: [String: JSONValue], ttl: Int, options: VideoUploadOptions, cancellation: CancellationToken, emit: @escaping @Sendable (Int64) async -> Void, permits: UploadPermitPool) async throws -> UploadedPart {
        let offset = Int64(number - 1) * session.partSize; let length = partLength(source.length, session.partSize, number); var item = signed
        for attempt in 1 ... options.maxPartAttempts {
            try await cancellation.throwIfCanceled()
            do {
                let headers = item["headers"]?.objectValue?.mapValues { $0.stringValue ?? "" } ?? [:]
                guard let url = URL(string: item["url"]?.stringValue ?? "") else { throw ValidationError("signed upload URL is empty or invalid") }
                let result = try await permits.run(cancellation) { try await signedUploads.put(source: source, range: offset ..< offset + length, url: url, headers: headers, timeout: options.partTimeout, cancellation: cancellation, progress: emit) }
                let expected = result.md5.isEmpty ? try await md5Hex(source, offset: offset, length: length) : result.md5
                guard !result.etag.isEmpty, result.etag.lowercased() == expected.lowercased() else { throw APIError("multipart part ETag mismatch", body: .object(["part_number": .int(Int64(number))])) }
                return UploadedPart(number: number, etag: result.etag, size: length, md5: expected, attempts: attempt)
            } catch {
                let local = try await md5Hex(source, offset: offset, length: length)
                if let found = try await reconcilePart(session, number: number, length: length, localMD5: local, cancellation: cancellation) { return UploadedPart(number: number, etag: found, size: length, md5: local, attempts: attempt) }
                if let api = error as? APIError, api.statusCode == 403, attempt < options.maxPartAttempts {
                    let refreshed = jsonObjects(try await multipartSign(session, numbers: [number], ttl: ttl, cancellation: cancellation)["parts"])
                    guard refreshed.count == 1, refreshed[0]["part_number"]?.intValue == number else { throw APIError("multipart URL refresh returned no matching part") }
                    item = refreshed[0]
                } else {
                    let api = error as? APIError
                    let retryable = error is SignedUploadFailure || error is TransportError || (api.map { [408, 429, 500, 502, 503, 504].contains($0.statusCode) } ?? false)
                    guard retryable, attempt < options.maxPartAttempts else { throw error }
                }
                try await multipartDelay(attempt: attempt, cancellation: cancellation)
            }
        }
        throw APIError("multipart part attempts exhausted")
    }

    private func reconcilePart(_ session: MultipartSession, number: Int, length: Int64, localMD5: String, cancellation: CancellationToken) async throws -> String? {
        for row in jsonObjects(try await multipartStatus(session, cancellation: cancellation)["parts"]) where row["part_number"]?.intValue == number && row["size_bytes"]?.intValue == Int(length) && (row["etag"]?.stringValue ?? "").lowercased() == localMD5.lowercased() { return row["etag"]?.stringValue }
        return nil
    }
    private func multipartFinalParts(_ session: MultipartSession, size: Int64, status: [String: JSONValue]) throws -> [(number: Int, etag: String)] {
        let remote = jsonObjects(status["parts"]).sorted { ($0["part_number"]?.intValue ?? 0) < ($1["part_number"]?.intValue ?? 0) }
        guard remote.count == session.partCount else { throw APIError("multipart status is missing, duplicate, or unsorted parts") }
        var out: [(Int, String)] = []
        for (index, row) in remote.enumerated() {
            let number = row["part_number"]?.intValue ?? 0; let etag = row["etag"]?.stringValue ?? ""; let expected = session.partMD5[number] ?? ""
            guard number == index + 1, row["size_bytes"]?.intValue == Int(partLength(size, session.partSize, number)), !etag.isEmpty, !expected.isEmpty, etag.lowercased() == expected.lowercased() else { throw APIError("multipart status returned an invalid part", body: .object(["part_number": .int(Int64(number))])) }
            out.append((number, etag))
        }
        return out
    }
}

private actor MultipartProgress {
    let total: Int64; var parts: [Int: Int64] = [:]; var sent: Int64
    init(total: Int64, initial: Int64) { self.total = total; sent = initial }
    func update(number: Int, bytes: Int64) -> UploadProgress? { let old = parts[number] ?? 0; let next = max(old, bytes); guard next > old else { return nil }; parts[number] = next; sent += next - old; return .init(uploadedBytes: min(sent, total), totalBytes: total) }
    func snapshot() -> UploadProgress { .init(uploadedBytes: min(sent, total), totalBytes: total) }
}

private func sessionQuery(_ session: MultipartSession) -> [URLQueryItem] { [.init(name: "request_id", value: session.requestID), .init(name: "upload_id", value: session.uploadID), .init(name: "key", value: session.key)] }
private func partLength(_ size: Int64, _ partSize: Int64, _ number: Int) -> Int64 { min(partSize, size - Int64(number - 1) * partSize) }
private func partCount(_ size: Int64, _ partSize: Int64) -> Int { size <= 0 ? 1 : Int(1 + (size - 1) / partSize) }
private func jsonObjects(_ value: JSONValue?) -> [[String: JSONValue]] { guard case .array(let rows) = value else { return [] }; return rows.compactMap(\.objectValue) }
private func jsonString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(data: try! encoder.encode(value), encoding: .utf8)!
}
private func jsonScalar(_ value: JSONValue) -> String { switch value { case .string(let text): return jsonString(text); case .int(let number): return String(number); default: return String(data: try! JSONEncoder().encode(value), encoding: .utf8)! } }
private func multipartDelay(attempt: Int, cancellation: CancellationToken) async throws {
    let shift = min(attempt - 1, 6); let ms = min(30_000, 250 * (1 << shift))
    try await withThrowingTaskGroup(of: Void.self) { group in group.addTask { try await Task.sleep(for: .milliseconds(ms)) }; group.addTask { await cancellation.whenCanceled(); throw OperationCanceledError() }; _ = try await group.next(); group.cancelAll() }
}
private func multipartResponse(_ source: UploadSource, session: MultipartSession, etag: String, resumed: Bool, attempts: Int, done: [String: JSONValue]) -> VideoUploadResponse {
    var raw: [String: JSONValue] = ["filename": .string(source.filename), "size_bytes": .int(source.length), "status_code": .int(200), "uploaded": .bool(true), "upload_strategy": .string("multipart"), "upload_id": .string(session.uploadID), "key": .string(session.key), "etag": .string(etag), "part_size_bytes": .int(session.partSize), "part_count": .int(Int64(session.partCount)), "parts_uploaded": .int(Int64(session.partCount)), "resumed": .bool(resumed), "attempt_count": .int(Int64(attempts)), "upload_done": .object(done), "dest_path": done["dest_path"] ?? .string("")]
    for key in ["video_filename", "start_datetime_user", "start_ts_unix_user_ms", "timestamp_source"] { if let value = done[key] { raw[key] = value } }
    return VideoUploadResponse(raw: raw)
}
