import Foundation

public struct SearchesResource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }

    public func searchVideo(_ request: SearchRequest, cancellation: CancellationToken? = nil) async throws -> SearchResponse {
        try request.validate()
        return SearchResponse(raw: try await http.requestJSON(
            "POST", Routes.full(Routes.searchClient), json: request.json(), cancellation: cancellation
        ))
    }

    public func searchBatch(
        _ requests: [SearchRequest], batchSize: Int = 10, nWorker: Int = 4,
        cancellation: CancellationToken? = nil
    ) async throws -> [SearchResponse] {
        guard batchSize > 0 else { throw ValidationError("batchSize must be greater than zero") }
        guard nWorker > 0 else { throw ValidationError("nWorker must be greater than zero") }
        for request in requests { try request.validate() }
        guard !requests.isEmpty else { return [] }

        let batches = stride(from: 0, to: requests.count, by: batchSize).map {
            ($0, Array(requests[$0 ..< min($0 + batchSize, requests.count)]))
        }
        return try await withThrowingTaskGroup(of: SearchBatchOutcome.self) { group in
            var next = 0
            var values = Array<SearchResponse?>(repeating: nil, count: requests.count)
            var failure: (Int, Error)?
            func add(_ item: (Int, [SearchRequest])) {
                group.addTask {
                    var out: [SearchResponse] = []
                    for (offset, request) in item.1.enumerated() {
                        do {
                            if let cancellation { try await cancellation.throwIfCanceled() }
                            out.append(try await searchVideo(request, cancellation: cancellation))
                        } catch {
                            return .failure(item.0 + offset, error)
                        }
                    }
                    return .success(item.0, out)
                }
            }
            while next < min(nWorker, batches.count) { add(batches[next]); next += 1 }
            while let outcome = try await group.next() {
                switch outcome {
                case .success(let start, let out):
                    for (offset, value) in out.enumerated() { values[start + offset] = value }
                case .failure(let index, let error):
                    if failure == nil || index < failure!.0 { failure = (index, error) }
                }
                if failure == nil, next < batches.count { add(batches[next]); next += 1 }
            }
            if let failure { throw failure.1 }
            return values.map { $0! }
        }
    }
}

private enum SearchBatchOutcome: @unchecked Sendable {
    case success(Int, [SearchResponse])
    case failure(Int, Error)
}
