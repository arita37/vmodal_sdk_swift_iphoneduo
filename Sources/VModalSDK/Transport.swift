import Foundation

public let jsonResponseLimitBytes: Int64 = 8 * 1_024 * 1_024
public let textResponseLimitBytes: Int64 = 8 * 1_024 * 1_024
public let errorResponseLimitBytes: Int64 = 1 * 1_024 * 1_024
public let binaryResponseLimitBytes: Int64 = 64 * 1_024 * 1_024
public let checkpointLimitBytes: Int64 = 1 * 1_024 * 1_024

public actor CancellationToken {
    private var canceled = false
    private var waits: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var isCanceled: Bool { canceled }

    public func cancel() {
        guard !canceled else { return }
        canceled = true
        let pending = waits.values
        waits.removeAll()
        for wait in pending { wait.resume() }
    }

    public func throwIfCanceled() throws {
        if canceled { throw OperationCanceledError() }
    }

    public func whenCanceled() async {
        if canceled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait in waits[id] = wait }
        } onCancel: {
            Task { await self.removeWait(id) }
        }
    }

    private func removeWait(_ id: UUID) {
        waits.removeValue(forKey: id)?.resume()
    }
}

public enum VModalResponseMode: Sendable {
    case json
    case bytes
    case text
}

public struct VModalFilePart: Sendable {
    public typealias StreamOpener = @Sendable () throws -> AsyncThrowingStream<Data, Error>

    public let fieldName: String
    public let filename: String
    public let length: Int64
    public let contentType: String
    public let open: StreamOpener

    public init(
        fieldName: String,
        filename: String,
        length: Int64,
        contentType: String,
        open: @escaping StreamOpener
    ) throws {
        try Self.validate(fieldName, max: 128, field: "multipart field name")
        try Self.validate(filename, max: 1024, field: "filename")
        try Self.validate(contentType, max: 255, field: "content type")
        guard length >= 0 else { throw ValidationError("file length must not be negative") }
        self.fieldName = fieldName
        self.filename = filename
        self.length = length
        self.contentType = contentType
        self.open = open
    }

    public static func file(fieldName: String, url: URL, contentType: String? = nil) throws -> VModalFilePart {
        guard url.isFileURL else { throw ValidationError("file URL is required") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw ValidationError("file does not exist")
        }
        return try VModalFilePart(
            fieldName: fieldName,
            filename: url.lastPathComponent,
            length: Int64(size),
            contentType: contentType ?? mimeType(for: url),
            open: { fileByteStream(url) }
        )
    }

    private static func validate(_ value: String, max: Int, field: String) throws {
        guard !value.isEmpty, value.count <= max else { throw ValidationError("invalid \(field)") }
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ValidationError("invalid \(field)")
        }
    }
}

public struct VModalRequest: Sendable, CustomStringConvertible {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let jsonBody: JSONValue?
    public let formFields: [URLQueryItem]
    public let files: [VModalFilePart]
    public let responseMode: VModalResponseMode
    public let cancellation: CancellationToken
    public let timeout: Duration

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        jsonBody: JSONValue? = nil,
        formFields: [URLQueryItem] = [],
        files: [VModalFilePart] = [],
        responseMode: VModalResponseMode = .json,
        cancellation: CancellationToken = CancellationToken(),
        timeout: Duration = .seconds(30)
    ) {
        self.method = method.uppercased()
        self.url = url
        self.headers = headers
        self.jsonBody = jsonBody
        self.formFields = formFields
        self.files = files
        self.responseMode = responseMode
        self.cancellation = cancellation
        self.timeout = timeout
    }

    public var description: String {
        "VModalRequest(method=\(method), pathType=absolute, queryItemCount=\(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count ?? 0), headerNames=\(headers.keys.sorted()), hasJSONBody=\(jsonBody != nil), formFieldNames=\(formFields.map(\.name)), fileCount=\(files.count))"
    }
}

public struct VModalResponse: Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let headers: [String: String]
    public let declaredLength: Int64
    public let body: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        declaredLength: Int64 = -1,
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.declaredLength = declaredLength
        self.body = body
    }

    public var description: String {
        "VModalResponse(statusCode=\(statusCode), headerNames=\(headers.keys.sorted()), declaredLength=\(declaredLength))"
    }
}

public protocol VModalTransport: Sendable {
    func send(_ request: VModalRequest) async throws -> VModalResponse
    func close() async
}

func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "json": return "application/json"
    case "jsonl": return "application/x-ndjson"
    case "txt": return "text/plain"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "mp4": return "video/mp4"
    default: return "application/octet-stream"
    }
}

private func fileByteStream(_ url: URL) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task.detached {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while !Task.isCancelled {
                    let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                    if data.isEmpty { break }
                    continuation.yield(data)
                }
                if Task.isCancelled { throw OperationCanceledError() }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
