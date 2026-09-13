import Foundation

public final class HTTPClient: Sendable {
    public let config: SDKConfig
    public let transport: any VModalTransport

    public init(config: SDKConfig, transport: any VModalTransport) {
        self.config = config
        self.transport = transport
    }

    public func headers(forceToken: Bool = false, requireUserID: Bool = true) async throws -> [String: String] {
        var values: [String: String] = [:]
        if config.mode == .direct {
            if requireUserID && config.userID == nil { throw AuthenticationError("user_id is required") }
            if let value = config.userID { values["X-User-Id"] = try validateHeaderValue(value) }
            if let value = config.tenantID { values["X-Tenant-Id"] = try validateHeaderValue(value) }
            if let value = config.email { values["X-User-Email"] = try validateHeaderValue(value) }
        }
        if forceToken || config.mode != .direct {
            values["Authorization"] = "Bearer \(try await config.currentAPIKey())"
        }
        try assertGatewayHeaders(values)
        return values
    }

    public func requestJSON(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        formFields: [URLQueryItem] = [],
        files: [VModalFilePart] = [],
        queryItems: [URLQueryItem] = [],
        cancellation: CancellationToken? = nil
    ) async throws -> [String: JSONValue] {
        try await executeJSON(
            method, path, headers: headers(), json: json, formFields: formFields,
            files: files, queryItems: queryItems, usersAPI: false, cancellation: cancellation
        )
    }

    public func requestUsersJSON(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        queryItems: [URLQueryItem] = [],
        cancellation: CancellationToken? = nil
    ) async throws -> [String: JSONValue] {
        try await executeJSON(
            method, path, headers: headers(forceToken: true, requireUserID: false), json: json,
            formFields: [], files: [], queryItems: queryItems, usersAPI: true, cancellation: cancellation
        )
    }

    public func requestBytes(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        queryItems: [URLQueryItem] = [],
        maxBytes: Int64? = nil,
        cancellation: CancellationToken? = nil
    ) async throws -> Data {
        let limit = try binaryLimit(maxBytes)
        let token = cancellation ?? CancellationToken()
        return try await execute(
            method, path, headers: headers(), json: json, queryItems: queryItems,
            responseMode: .bytes, usersAPI: false, cancellation: token
        ) { response, attempt in
            try await readBounded(response, limit: limit, idleTimeout: self.config.responseIdleTimeout, cancellation: attempt)
        }
    }

    public func requestStream(
        _ method: String,
        _ path: String,
        json: JSONValue? = nil,
        queryItems: [URLQueryItem] = [],
        maxBytes: Int64? = nil,
        cancellation: CancellationToken? = nil,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64 {
        let limit = try binaryLimit(maxBytes)
        let token = cancellation ?? CancellationToken()
        return try await execute(
            method, path, headers: headers(), json: json, queryItems: queryItems,
            responseMode: .bytes, usersAPI: false, cancellation: token
        ) { response, attempt in
            try await readBoundedStream(
                response, limit: limit, idleTimeout: self.config.responseIdleTimeout,
                cancellation: attempt, sink: sink
            )
        }
    }

    public func close() async { await transport.close() }

    private func executeJSON(
        _ method: String,
        _ path: String,
        headers: [String: String],
        json: JSONValue?,
        formFields: [URLQueryItem],
        files: [VModalFilePart],
        queryItems: [URLQueryItem],
        usersAPI: Bool,
        cancellation: CancellationToken?
    ) async throws -> [String: JSONValue] {
        let token = cancellation ?? CancellationToken()
        return try await execute(
            method, path, headers: headers, json: json, formFields: formFields, files: files,
            queryItems: queryItems, responseMode: .json, usersAPI: usersAPI, cancellation: token
        ) { response, attempt in
            let data = try await readBounded(
                response, limit: jsonResponseLimitBytes,
                idleTimeout: self.config.responseIdleTimeout, cancellation: attempt
            )
            return try JSONValue.decodeObject(data)
        }
    }

    private func execute<T: Sendable>(
        _ method: String,
        _ path: String,
        headers: [String: String],
        json: JSONValue?,
        formFields: [URLQueryItem] = [],
        files: [VModalFilePart] = [],
        queryItems: [URLQueryItem],
        responseMode: VModalResponseMode,
        usersAPI: Bool,
        cancellation: CancellationToken,
        reader: @escaping @Sendable (VModalResponse, CancellationToken) async throws -> T
    ) async throws -> T {
        let normalized = method.uppercased()
        let canRetry = normalized == "GET" || normalized == "HEAD"
        let url = try makeURL(path, queryItems: queryItems, usersAPI: usersAPI)
        for attempt in 0 ... config.maxRetries {
            try await cancellation.throwIfCanceled()
            let attemptCancellation = CancellationToken()
            let callerWatch = Task {
                await cancellation.whenCanceled()
                await attemptCancellation.cancel()
            }
            defer { callerWatch.cancel() }
            do {
                let request = VModalRequest(
                    method: normalized, url: url, headers: headers, jsonBody: json,
                    formFields: formFields, files: files, responseMode: responseMode,
                    cancellation: attemptCancellation, timeout: config.requestTimeout
                )
                let response = try await transport.send(request)
                if canRetry && [500, 502, 503, 504].contains(response.statusCode) && attempt < config.maxRetries {
                    _ = try await readBounded(response, limit: errorResponseLimitBytes, idleTimeout: config.responseIdleTimeout, cancellation: attemptCancellation)
                    callerWatch.cancel()
                    try await retryDelay(attempt: attempt, cancellation: cancellation)
                    continue
                }
                guard (200 ... 299).contains(response.statusCode) else {
                    try await raiseForStatus(response, cancellation: attemptCancellation)
                }
                let value = try await reader(response, attemptCancellation)
                try await cancellation.throwIfCanceled()
                callerWatch.cancel()
                return value
            } catch is OperationCanceledError {
                callerWatch.cancel()
                if await cancellation.isCanceled { throw OperationCanceledError() }
                guard canRetry && attempt < config.maxRetries else { throw TransportError() }
                try await retryDelay(attempt: attempt, cancellation: cancellation)
            } catch let error as TransportError {
                callerWatch.cancel()
                if await cancellation.isCanceled { throw OperationCanceledError() }
                guard canRetry && attempt < config.maxRetries else { throw error }
                try await retryDelay(attempt: attempt, cancellation: cancellation)
            }
        }
        throw TransportError()
    }

    private func raiseForStatus(_ response: VModalResponse, cancellation: CancellationToken) async throws -> Never {
        let data = try await readBounded(
            response, limit: errorResponseLimitBytes,
            idleTimeout: config.responseIdleTimeout, cancellation: cancellation
        )
        let body = redactBody(data)
        if response.statusCode == 401 {
            throw AuthenticationError(statusCode: 401, body: body)
        }
        if response.statusCode == 422 {
            let detail = body?.objectValue?["detail"].map(String.init(describing:))
            throw ValidationError(statusCode: 422, body: body, details: detail)
        }
        throw APIError(statusCode: response.statusCode, body: body)
    }

    private func makeURL(_ path: String, queryItems: [URLQueryItem], usersAPI: Bool) throws -> URL {
        let base = usersAPI ? config.usersAPIBaseURL : config.baseURL
        let target: URL
        if let absolute = URL(string: path), absolute.scheme != nil { target = absolute }
        else { target = base.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path) }
        try requireSameOrigin(target, base: base)
        var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)
        let existing = parts?.queryItems ?? []
        parts?.queryItems = existing + queryItems
        guard let url = parts?.url else { throw ValidationError("invalid HTTP URL") }
        return url
    }

    private func requireSameOrigin(_ target: URL, base: URL) throws {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        guard target.scheme?.lowercased() == base.scheme?.lowercased(),
              target.host?.lowercased() == base.host?.lowercased(), port(target) == port(base)
        else { throw ValidationError("absolute API URL must match the configured origin") }
    }

    private func assertGatewayHeaders(_ headers: [String: String]) throws {
        guard config.mode == .gateway else { return }
        let forbidden = ["x-user-id", "x-tenant-id", "x-user-email", "x-userid"]
        guard !headers.keys.contains(where: { forbidden.contains($0.lowercased()) }) else {
            throw ValidationError("gateway request contains forbidden identity headers")
        }
    }

    private func binaryLimit(_ value: Int64?) throws -> Int64 {
        guard let value else { return binaryResponseLimitBytes }
        guard value > 0, value <= binaryResponseLimitBytes else {
            throw ValidationError("max_bytes must be positive and no larger than the SDK binary limit")
        }
        return value
    }

    private func retryDelay(attempt: Int, cancellation: CancellationToken) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(for: .milliseconds(50 * (attempt + 1))) }
            group.addTask { await cancellation.whenCanceled(); throw OperationCanceledError() }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private enum BodyEvent: Sendable {
    case chunk(Data)
    case end
    case failure(String)
    case overflow(Int64)
}

private actor BodyReader {
    private var events: [BodyEvent] = []
    private var waits: [CheckedContinuation<BodyEvent, Never>] = []
    private var buffered: Int64 = 0
    private let limit: Int64
    private var ended = false

    private init(limit: Int64) { self.limit = limit }

    static func make(_ stream: AsyncThrowingStream<Data, Error>, limit: Int64) -> BodyReader {
        let reader = BodyReader(limit: limit)
        Task { await reader.consume(stream) }
        return reader
    }

    func next() async throws -> Data? {
        let event: BodyEvent
        if events.isEmpty { event = await withCheckedContinuation { waits.append($0) } }
        else {
            event = events.removeFirst()
            if case .chunk(let data) = event { buffered -= Int64(data.count) }
        }
        switch event {
        case .chunk(let data): return data
        case .end: return nil
        case .failure(let text): throw TransportError(text)
        case .overflow(let observed): throw ResponseTooLargeError(limitBytes: limit, observedBytes: observed)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<Data, Error>) async {
        do {
            for try await chunk in stream {
                if !emit(.chunk(chunk)) { break }
            }
            emit(.end)
        } catch { emit(.failure(String(describing: error))) }
    }

    @discardableResult
    private func emit(_ event: BodyEvent) -> Bool {
        guard !ended else { return false }
        if case .chunk(let data) = event, waits.isEmpty {
            let observed = buffered + Int64(data.count)
            guard observed <= limit else {
                ended = true
                events.append(.overflow(observed))
                return false
            }
            buffered = observed
        }
        if case .end = event { ended = true }
        if case .failure = event { ended = true }
        if waits.isEmpty { events.append(event) }
        else { waits.removeFirst().resume(returning: event) }
        return true
    }
}

public func readBounded(
    _ response: VModalResponse,
    limit: Int64,
    idleTimeout: Duration,
    cancellation: CancellationToken
) async throws -> Data {
    guard response.declaredLength >= -1 else { await cancellation.cancel(); throw MalformedResponseError("malformed content length") }
    if response.declaredLength > limit {
        await cancellation.cancel()
        throw ResponseTooLargeError(limitBytes: limit, observedBytes: response.declaredLength)
    }
    let reader = BodyReader.make(response.body, limit: limit)
    var data = Data()
    while true {
        try await cancellation.throwIfCanceled()
        let chunk = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await reader.next() }
            group.addTask { try await Task.sleep(for: idleTimeout); await cancellation.cancel(); throw TransportError("response idle timeout") }
            group.addTask { await cancellation.whenCanceled(); throw OperationCanceledError() }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
        guard let chunk else { return data }
        let observed = Int64(data.count) + Int64(chunk.count)
        guard observed <= limit else { await cancellation.cancel(); throw ResponseTooLargeError(limitBytes: limit, observedBytes: observed) }
        data.append(chunk)
    }
}

public func readBoundedStream(
    _ response: VModalResponse,
    limit: Int64,
    idleTimeout: Duration,
    cancellation: CancellationToken,
    sink: @escaping @Sendable (Data) throws -> Void
) async throws -> Int64 {
    guard response.declaredLength >= -1 else { await cancellation.cancel(); throw MalformedResponseError("malformed content length") }
    if response.declaredLength > limit {
        await cancellation.cancel()
        throw ResponseTooLargeError(limitBytes: limit, observedBytes: response.declaredLength)
    }
    let reader = BodyReader.make(response.body, limit: limit)
    var observed: Int64 = 0
    while true {
        try await cancellation.throwIfCanceled()
        let chunk = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await reader.next() }
            group.addTask { try await Task.sleep(for: idleTimeout); await cancellation.cancel(); throw TransportError("response idle timeout") }
            group.addTask { await cancellation.whenCanceled(); throw OperationCanceledError() }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
        guard let chunk else { return observed }
        observed += Int64(chunk.count)
        guard observed <= limit else { await cancellation.cancel(); throw ResponseTooLargeError(limitBytes: limit, observedBytes: observed) }
        try sink(chunk)
    }
}

private func redactBody(_ data: Data) -> JSONValue? {
    guard !data.isEmpty else { return nil }
    if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { return redact(value) }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }
    return .string(redactPaths(text))
}

private func redact(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text): return .string(redactPaths(text))
    case .array(let values): return .array(values.map(redact))
    case .object(let values): return .object(values.mapValues(redact))
    default: return value
    }
}

private func redactPaths(_ text: String) -> String {
    let patterns = [
        #"file:(?://)?[^\s\"']+"#,
        #"\\\\[^\s\"']+"#,
        #"[A-Za-z]:\\[^\s\"']+"#,
        #"/(?:Users|home|var|tmp|private|opt|srv|mnt)/[^\s\"']+"#,
    ]
    return patterns.reduce(text) { value, pattern in
        value.replacingOccurrences(of: pattern, with: "****", options: .regularExpression)
    }
}
