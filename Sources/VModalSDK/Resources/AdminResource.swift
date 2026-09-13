import Foundation

public struct AdminResource: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }
    public func userStats(cancellation: CancellationToken? = nil) async throws -> AdminUserStatsResponse { AdminUserStatsResponse(raw: try await http.requestJSON("GET", Routes.full(Routes.adminUserStats), cancellation: cancellation)) }
    public func usage(date: String = "", cancellation: CancellationToken? = nil) async throws -> UsageUserDetail {
        let clean = date.trimmingCharacters(in: .whitespacesAndNewlines)
        return UsageUserDetail(raw: try await http.requestUsersJSON("GET", Routes.usersFull(Routes.adminUsage), queryItems: clean.isEmpty ? [] : [.init(name: "date", value: clean)], cancellation: cancellation))
    }
    public func cacheStats(cancellation: CancellationToken? = nil) async throws -> CacheStats { CacheStats(raw: try await http.requestUsersJSON("GET", Routes.usersFull(Routes.adminCacheStats), cancellation: cancellation)) }
}
