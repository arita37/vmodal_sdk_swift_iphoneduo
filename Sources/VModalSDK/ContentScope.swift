import Foundation

public struct ContentScope: Sendable, Equatable {
    public let projectID: String
    public let collectionName: String
    public let streamName: String
    public let backendCollectionName: String

    public init(projectID: String, collectionName: String, streamName: String) throws {
        let project = try Self.normalize(projectID, field: "projectID", reservedSeparator: true)
        let collection = try Self.normalize(collectionName, field: "collectionName", reservedSeparator: true)
        let stream = try Self.normalize(streamName, field: "streamName")
        let backend = "\(project)__\(collection)"
        guard backend.count <= 80 else {
            throw ValidationError("projectID and collectionName must encode to at most 80 characters")
        }
        self.projectID = project
        self.collectionName = collection
        self.streamName = stream
        self.backendCollectionName = backend
    }

    public static func project(_ value: String) throws -> String {
        try normalize(value, field: "projectID", reservedSeparator: true)
    }

    public static func decodeCollection(projectID: String, backendName: String) throws -> String? {
        let project = try self.project(projectID)
        let prefix = "\(project)__"
        guard backendName.hasPrefix(prefix) else { return nil }
        do {
            let name = String(backendName.dropFirst(prefix.count))
            let collection = try normalize(name, field: "collectionName", reservedSeparator: true)
            guard backendName.count <= 80 else { throw ValidationError("encoded name is too long") }
            return collection
        } catch {
            throw MalformedResponseError("collection listing returned an invalid collectionName")
        }
    }

    private static func normalize(
        _ value: String,
        field: String,
        reservedSeparator: Bool = false
    ) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ValidationError("\(field) is required") }
        guard clean.count <= 80 else { throw ValidationError("\(field) must be at most 80 characters") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard clean.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ValidationError("\(field) must contain only letters, digits, and underscore")
        }
        guard !reservedSeparator || !clean.contains("__") else {
            throw ValidationError("\(field) must not contain the reserved separator \"__\"")
        }
        return clean
    }
}
