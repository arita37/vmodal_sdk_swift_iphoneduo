import Foundation

public struct IndexesResource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }

    public func jobsList(status: String? = nil, mode: String? = nil, groupName: String? = nil, limit: Int = 200, cancellation: CancellationToken? = nil) async throws -> IndexationJobsListResponse {
        guard (1 ... 1_000).contains(limit) else { throw ValidationError("limit must be between 1 and 1000") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(.init(name: "status", value: status)) }
        if let mode { query.append(.init(name: "mode", value: mode)) }
        if let groupName { query.append(.init(name: "group_name", value: groupName)) }
        return IndexationJobsListResponse(raw: try await http.requestJSON("GET", Routes.full(Routes.indexationJobs), queryItems: query, cancellation: cancellation))
    }

    public func createIndex(_ request: IndexationSubmitRequest, cancellation: CancellationToken? = nil) async throws -> IndexationSubmitResponse {
        try request.validate()
        return IndexationSubmitResponse(raw: try await http.requestJSON("POST", Routes.full(Routes.indexationSubmit), json: request.json(), cancellation: cancellation))
    }

    public func indexStatus(_ jobID: String, cancellation: CancellationToken? = nil) async throws -> IndexationStatusResponse {
        let clean = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ValidationError("job_id is required") }
        let path = try Routes.replacingPathSegment(in: Routes.indexationStatus, placeholder: "job_id", value: clean)
        do {
            return IndexationStatusResponse(raw: try await http.requestJSON("GET", Routes.full(path), cancellation: cancellation))
        } catch let error as APIError where error.statusCode == 404 {
            let jobs = try await jobsList(limit: 1_000, cancellation: cancellation)
            guard let row = jobs.data.compactMap(\.objectValue).first(where: { $0["job_id"]?.stringValue == clean }) else { throw error }
            return IndexationStatusResponse(raw: row)
        }
    }

    public func deleteIndex(_ request: IndexationDeleteRequest, cancellation: CancellationToken? = nil) async throws -> IndexationDeleteResponse {
        try request.validate()
        return IndexationDeleteResponse(raw: try await http.requestJSON("DELETE", Routes.full(Routes.indexationDelete), json: request.json(), cancellation: cancellation))
    }

    public func embeddingModels() throws -> Never { throw FeatureDisabledError("embedding models endpoint is disabled on server") }
}
