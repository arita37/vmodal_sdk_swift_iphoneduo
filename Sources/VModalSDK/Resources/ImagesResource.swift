import Foundation

public struct ImagesResource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }

    public func getURL(mode: String, groupName: String, modality: String, filename: String, streamName: String = "astream", tsUnix13digits: String? = nil, userid: String? = nil, cancellation: CancellationToken? = nil) async throws -> ImageURLResponse {
        var json: [String: JSONValue] = ["mode": .string(mode), "group_name": .string(groupName), "modality": .string(modality), "stream_name": .string(streamName), "filename": .string(filename)]
        if let tsUnix13digits { json["ts_unix_13digits"] = .string(tsUnix13digits) }
        if http.config.mode == .direct, let userid, !userid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { json["userid"] = .string(userid) }
        return ImageURLResponse(raw: try await http.requestJSON("POST", Routes.full(Routes.imageGetURL), json: .object(json), cancellation: cancellation))
    }

    public func getURLBulk(_ records: [[String: JSONValue]], userid: String? = nil, cancellation: CancellationToken? = nil) async throws -> ImageURLBulkResponse {
        let safe = records.map { row in
            guard http.config.mode == .gateway else { return row }
            return row.filter { $0.key != "userid" && $0.key != "user_id" }
        }
        var json: [String: JSONValue] = ["records": .array(safe.map(JSONValue.object))]
        if http.config.mode == .direct, let userid, !userid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { json["userid"] = .string(userid) }
        return ImageURLBulkResponse(raw: try await http.requestJSON("POST", Routes.full(Routes.imageGetURLBulk), json: .object(json), cancellation: cancellation))
    }

    public func getImageFromURL(_ urlPreSigned: String, userid: String? = nil, maxBytes: Int64? = nil, cancellation: CancellationToken? = nil) async throws -> Data {
        try await http.requestBytes("POST", Routes.full(Routes.imageGetImage), json: imagePayload(urlPreSigned, userid: userid), maxBytes: maxBytes, cancellation: cancellation)
    }

    public func writeImageFromURL(_ urlPreSigned: String, to output: OutputStream, userid: String? = nil, maxBytes: Int64? = nil, cancellation: CancellationToken? = nil) async throws {
        let box = OutputStreamBox(output)
        _ = try await http.requestStream(
            "POST", Routes.full(Routes.imageGetImage), json: imagePayload(urlPreSigned, userid: userid),
            maxBytes: maxBytes, cancellation: cancellation
        ) { try box.write($0) }
    }

    public func saveImageFromURL(_ urlPreSigned: String, to destination: URL, userid: String? = nil, maxBytes: Int64? = nil, cancellation: CancellationToken? = nil) async throws -> URL {
        guard destination.isFileURL else { throw ValidationError("destination must be a file URL") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw TransportError("unable to create image staging file")
            }
            let handle = try FileHandle(forWritingTo: temp)
            let box = FileHandleBox(handle)
            do {
                _ = try await http.requestStream(
                    "POST", Routes.full(Routes.imageGetImage), json: imagePayload(urlPreSigned, userid: userid),
                    maxBytes: maxBytes, cancellation: cancellation
                ) { try box.write($0) }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else { try FileManager.default.moveItem(at: temp, to: destination) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public func getImageBulkFromURLs(_ urls: [String], userid: String? = nil, cancellation: CancellationToken? = nil) async throws -> ImageGetBulkResponse {
        var json: [String: JSONValue] = ["urls": .array(urls.map(JSONValue.string))]
        if http.config.mode == .direct, let userid, !userid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { json["userid"] = .string(userid) }
        return ImageGetBulkResponse(raw: try await http.requestJSON("POST", Routes.full(Routes.imageGetImageBulk), json: .object(json), cancellation: cancellation))
    }

    private func imagePayload(_ url: String, userid: String?) -> JSONValue {
        var json: [String: JSONValue] = ["url_pre_signed": .string(url)]
        if http.config.mode == .direct, let userid, !userid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { json["userid"] = .string(userid) }
        return .object(json)
    }
}

// Foundation streams are externally synchronized by these single-operation
// wrappers; the SDK never shares either object across concurrent downloads.
private final class OutputStreamBox: @unchecked Sendable {
    let output: OutputStream
    init(_ output: OutputStream) { self.output = output }
    func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress! + sent, maxLength: data.count - sent)
            }
            guard count > 0 else { throw TransportError("output stream write failed") }
            sent += count
        }
    }
}

private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
}
