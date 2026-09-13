import Foundation

public struct GDriveResource: Sendable {
    public init() {}
    public func privateAuthURL() throws -> Never { throw FeatureDisabledError("private google drive auth endpoint is disabled on server") }
    public func privateDownload() throws -> Never { throw FeatureDisabledError("private google drive download endpoint is disabled on server") }
}
public struct SQLResource: Sendable {
    public init() {}
    public func query() throws -> Never { throw FeatureDisabledError("sql query endpoint is disabled on server") }
}
