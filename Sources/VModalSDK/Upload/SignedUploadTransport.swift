import CryptoKit
import Foundation

public struct SignedUploadResult: Sendable, Equatable {
    public let statusCode: Int; public let etag: String; public let md5: String
    public init(statusCode: Int, etag: String = "", md5: String = "") { self.statusCode = statusCode; self.etag = etag; self.md5 = md5 }
}
public struct SignedUploadFailure: VModalError {
    public let message = "transport error"; public let statusCode = 0; public let body: JSONValue? = nil
    public let details: String?; public let sentBytes: Int64; public let localMD5: String
    public init(sentBytes: Int64, localMD5: String, details: String? = nil) { self.sentBytes = sentBytes; self.localMD5 = localMD5; self.details = details }
}

public protocol SignedUploadTransport: Sendable {
    func put(source: UploadSource, range: Range<Int64>?, url: URL, headers: [String: String], timeout: Duration, cancellation: CancellationToken, progress: @escaping @Sendable (Int64) async -> Void) async throws -> SignedUploadResult
    func close() async
}

public actor URLSessionSignedUploadTransport: SignedUploadTransport {
    private var closed = false
    public init() {}

    public func put(source: UploadSource, range: Range<Int64>? = nil, url: URL, headers: [String: String] = [:], timeout: Duration = .seconds(300), cancellation: CancellationToken, progress: @escaping @Sendable (Int64) async -> Void) async throws -> SignedUploadResult {
        guard !closed else { throw TransportError("signed transport is closed") }
        guard timeout > .zero else { throw ValidationError("signed upload timeout must be positive") }
        try await cancellation.throwIfCanceled()
        try validateSignedURL(url); let safe = try signedHeaders(headers)
        let selected = range ?? 0 ..< source.length
        let selectedLength = selected.upperBound - selected.lowerBound
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vmodal-upload-\(UUID().uuidString)")
        var digest = Insecure.MD5(); var written: Int64 = 0; var localMD5 = ""
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw TransportError("unable to create signed upload staging file")
        }
        do {
            let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }
            for try await chunk in try source.open(offset: selected.lowerBound, length: selectedLength) {
                try await cancellation.throwIfCanceled(); try handle.write(contentsOf: chunk); digest.update(data: chunk); written += Int64(chunk.count)
            }
            guard written == selectedLength else { throw TransportError("upload source length did not match Content-Length") }
            try handle.synchronize()
            localMD5 = digest.finalize().map { String(format: "%02x", $0) }.joined()
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpShouldHandleCookies = false
            for (key, value) in safe { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue(String(selectedLength), forHTTPHeaderField: "Content-Length")
            if safe.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                request.setValue(source.contentType, forHTTPHeaderField: "Content-Type")
            }
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            let delegate = SignedTaskDelegate(progress: progress)
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: temp) }
            let uploadRequest = request
            let pair = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await session.upload(for: uploadRequest, fromFile: temp, delegate: delegate) }
                group.addTask { await cancellation.whenCanceled(); throw OperationCanceledError() }
                group.addTask { try await Task.sleep(for: timeout); throw TransportError("signed upload phase timeout") }
                let result = try await group.next()!; group.cancelAll(); return result
            }
            guard let response = pair.1 as? HTTPURLResponse else { throw MalformedResponseError() }
            guard pair.0.count <= errorResponseLimitBytes else { throw ResponseTooLargeError(limitBytes: errorResponseLimitBytes, observedBytes: Int64(pair.0.count)) }
            guard (200 ... 299).contains(response.statusCode) else { throw APIError("signed upload failed", statusCode: response.statusCode, body: .string(String(decoding: pair.0, as: UTF8.self))) }
            let etag = (response.value(forHTTPHeaderField: "ETag") ?? "").replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return SignedUploadResult(statusCode: response.statusCode, etag: etag, md5: localMD5)
        } catch is OperationCanceledError { try? FileManager.default.removeItem(at: temp); throw OperationCanceledError() }
        catch let error as APIError { try? FileManager.default.removeItem(at: temp); throw error }
        catch { try? FileManager.default.removeItem(at: temp); throw SignedUploadFailure(sentBytes: written, localMD5: localMD5, details: String(describing: error)) }
    }

    public func close() async { closed = true }
}

// URLSession requires a reference-type delegate. It has immutable state only;
// its callback crosses Foundation's delegate boundary by design.
private final class SignedTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) async -> Void
    init(progress: @escaping @Sendable (Int64) async -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { Task { await progress(totalBytesSent) } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private func validateSignedURL(_ url: URL) throws {
    let host = url.host?.lowercased() ?? ""; let loopback = ["localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1"].contains(host)
    guard url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && loopback) else { throw ValidationError("invalid signed upload URL") }
}
private func signedHeaders(_ headers: [String: String]) throws -> [String: String] {
    let forbidden = ["authorization", "cookie", "origin", "referer", "x-user-id", "x-tenant-id", "x-user-email", "x-userid"]
    var out: [String: String] = [:]
    for (key, value) in headers {
        let lower = key.lowercased(); guard !forbidden.contains(lower) else { throw ValidationError("signed upload contains forbidden authentication headers") }
        guard ["content-md5", "content-type", "content-length"].contains(lower) || lower.hasPrefix("x-amz-") || lower.hasPrefix("x-goog-") else { throw ValidationError("signed upload header is not allowed") }
        out[key] = try validateHeaderValue(value)
    }
    return out
}
