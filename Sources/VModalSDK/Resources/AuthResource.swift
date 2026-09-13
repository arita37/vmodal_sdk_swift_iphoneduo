import Foundation

public struct AuthResource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }

    public func health(cancellation: CancellationToken? = nil) async throws -> HealthResponse {
        HealthResponse(raw: try await http.requestJSON("GET", Routes.full(Routes.health), cancellation: cancellation))
    }

    public func authCheck(cancellation: CancellationToken? = nil) async throws -> Bool {
        _ = try await health(cancellation: cancellation)
        return true
    }

    public func me(cancellation: CancellationToken? = nil) async throws -> UserProfile {
        UserProfile(raw: try await http.requestUsersJSON("GET", Routes.usersFull(Routes.authMe), cancellation: cancellation))
    }
}
