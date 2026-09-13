import Foundation

public protocol APIKeyProvider: Sendable {
    func current() async throws -> String
}

public actor MutableAPIKeyProvider: APIKeyProvider, CustomStringConvertible {
    private var key: String?
    private var isClosed = false

    public init(_ initialKey: String) throws {
        key = try validateAPIKey(initialKey)
    }

    public func current() throws -> String {
        guard !isClosed, let key else { throw AuthenticationError("API key is unavailable") }
        return key
    }

    public func rotate(_ newKey: String) throws {
        let valid = try validateAPIKey(newKey)
        guard !isClosed else { throw AuthenticationError("API key is unavailable") }
        key = valid
    }

    public func clear() { key = nil }

    public func close() {
        isClosed = true
        key = nil
    }

    public nonisolated var description: String { "MutableAPIKeyProvider([REDACTED])" }
}

func validateAPIKey(_ value: String) throws -> String {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw ValidationError("API key must not be blank") }
    guard key.count <= 8192 else { throw ValidationError("API key is too long") }
    guard !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw ValidationError("API key contains invalid characters")
    }
    return key
}

func validateHeaderValue(_ value: String) throws -> String {
    guard value.count <= 4096 else { throw ValidationError("header value is too long") }
    guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw ValidationError("header value contains invalid characters")
    }
    return value
}
