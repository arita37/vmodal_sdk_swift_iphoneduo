import Foundation

public actor URLSessionVModalTransport: VModalTransport {
    private var tasks: [UUID: URLSessionTask] = [:]
    private var closed = false

    public init() {}

    public func send(_ request: VModalRequest) async throws -> VModalResponse {
        guard !closed else { throw TransportError("transport is closed") }
        try await request.cancellation.throwIfCanceled()
        var value = URLRequest(url: request.url)
        value.httpMethod = request.method
        let duration = request.timeout.components
        value.timeoutInterval = max(0.001, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        value.httpShouldHandleCookies = false
        for (name, header) in request.headers { value.setValue(header, forHTTPHeaderField: name) }
        var temporaryBody: URL?
        if !request.files.isEmpty {
            let body = try await multipartBody(request.formFields, files: request.files, cancellation: request.cancellation)
            temporaryBody = body.url
            value.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
            value.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
        } else if let body = request.jsonBody {
            value.httpBody = try JSONEncoder().encode(body)
            value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if !request.formFields.isEmpty {
            var parts = URLComponents()
            parts.queryItems = request.formFields
            value.httpBody = parts.percentEncodedQuery?.data(using: .utf8)
            value.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let id = UUID()
        let owner = self
        let watchBox = WatchBox()
        let sessionBox = SessionBox()
        let cleanupURL = temporaryBody
        let delegate = StreamingDelegate(responseMode: request.responseMode) {
            Task {
                if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
                await sessionBox.take()?.finishTasksAndInvalidate()
                await watchBox.cancel()
                await owner.remove(id)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        await sessionBox.set(session)
        let task: URLSessionTask
        if let temporaryBody { task = session.uploadTask(with: value, fromFile: temporaryBody) }
        else { task = session.dataTask(with: value) }
        tasks[id] = task
        let cancelWatch = Task {
            await request.cancellation.whenCanceled()
            task.cancel()
        }
        await watchBox.set(cancelWatch)
        task.resume()
        do {
            let response = try await delegate.response()
            guard response.expectedContentLength >= -1 else { throw MalformedResponseError("malformed content length") }
            return VModalResponse(
                statusCode: response.statusCode,
                headers: response.allHeaderFields.reduce(into: [:]) { out, item in
                    out[String(describing: item.key)] = String(describing: item.value)
                },
                declaredLength: response.expectedContentLength,
                body: delegate.stream
            )
        } catch {
            task.cancel()
            if let temporaryBody { try? FileManager.default.removeItem(at: temporaryBody) }
            if await request.cancellation.isCanceled { throw OperationCanceledError() }
            throw TransportError(String(describing: error))
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let active = tasks.values
        tasks.removeAll()
        for task in active { task.cancel() }
    }

    private func remove(_ id: UUID) { tasks.removeValue(forKey: id) }
}

private func multipartBody(
    _ fields: [URLQueryItem], files: [VModalFilePart], cancellation: CancellationToken
) async throws -> (url: URL, boundary: String, length: Int64) {
    let boundary = "VModalBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vmodal-form-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw TransportError("unable to create multipart staging file")
    }
    do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var length: Int64 = 0
        func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
            length += Int64(data.count)
        }
        func safe(_ value: String) throws -> String {
            guard value.count <= 8 * 1_024,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { throw ValidationError("invalid multipart value") }
            return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        for field in fields {
            try await cancellation.throwIfCanceled()
            let name = try safe(field.name)
            let value = try safe(field.value ?? "")
            try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for file in files {
            try await cancellation.throwIfCanceled()
            let name = try safe(file.fieldName)
            let filename = try safe(file.filename)
            let contentType = try safe(file.contentType)
            try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
            var actual: Int64 = 0
            for try await chunk in try file.open() {
                try await cancellation.throwIfCanceled()
                actual += Int64(chunk.count)
                guard actual <= file.length else { throw TransportError("multipart source exceeded declared length") }
                try write(chunk)
            }
            guard actual == file.length else { throw TransportError("multipart source ended before declared length") }
            try write(Data("\r\n".utf8))
        }
        try write(Data("--\(boundary)--\r\n".utf8))
        return (url, boundary, length)
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

// URLSession owns and invokes its delegate concurrently. All changing response
// state is actor-isolated; the remaining properties are immutable Sendable values.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let state = StreamingState()
    private let limitLock = NSLock()
    private var observed: Int64 = 0
    private var limit: Int64
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let onFinish: @Sendable () -> Void

    init(responseMode: VModalResponseMode, onFinish: @escaping @Sendable () -> Void) {
        switch responseMode {
        case .json: limit = jsonResponseLimitBytes
        case .text: limit = textResponseLimitBytes
        case .bytes: limit = binaryResponseLimitBytes
        }
        var stored: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { stored = $0 }
        continuation = stored
        self.onFinish = onFinish
        super.init()
    }

    func response() async throws -> HTTPURLResponse { try await state.response() }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: MalformedResponseError())
            Task { await state.fail(MalformedResponseError()) }
            completionHandler(.cancel)
            return
        }
        if !(200 ... 299).contains(response.statusCode) {
            limitLock.lock()
            limit = min(limit, errorResponseLimitBytes)
            limitLock.unlock()
        }
        Task { await state.receive(response) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        limitLock.lock()
        observed += Int64(data.count)
        let count = observed
        let maximum = limit
        limitLock.unlock()
        guard count <= maximum else {
            let error = ResponseTooLargeError(limitBytes: maximum, observedBytes: count)
            continuation.finish(throwing: error)
            dataTask.cancel()
            Task { await state.fail(error) }
            return
        }
        continuation.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { continuation.finish(throwing: error); Task { await state.fail(error) } }
        else { continuation.finish() }
        onFinish()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor WatchBox {
    private var task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task?.cancel(); task = nil }
}

private actor SessionBox {
    private var session: URLSession?
    func set(_ session: URLSession) { self.session = session }
    func take() -> URLSession? { defer { session = nil }; return session }
}

private actor StreamingState {
    private var stored: HTTPURLResponse?
    private var failure: Error?
    private var wait: CheckedContinuation<HTTPURLResponse, Error>?

    func response() async throws -> HTTPURLResponse {
        if let stored { return stored }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { wait = $0 }
    }

    func receive(_ response: HTTPURLResponse) {
        stored = response
        wait?.resume(returning: response)
        wait = nil
    }

    func fail(_ error: Error) {
        failure = error
        wait?.resume(throwing: error)
        wait = nil
    }
}
