import Foundation

public protocol VModalError: Error, CustomStringConvertible, Sendable {
    var message: String { get }
    var statusCode: Int { get }
    var body: JSONValue? { get }
    var details: String? { get }
}

public extension VModalError {
    var description: String {
        statusCode == 0
            ? "\(String(describing: type(of: self))): \(message)"
            : "\(String(describing: type(of: self))): \(message) | status=\(statusCode)"
    }
}

public struct AuthenticationError: VModalError {
    public let message: String
    public let statusCode: Int
    public let body: JSONValue?
    public let details: String?

    public init(
        _ message: String = "authentication failed",
        statusCode: Int = 401,
        body: JSONValue? = nil,
        details: String? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.body = body
        self.details = details
    }
}

public struct APIError: VModalError {
    public let message: String
    public let statusCode: Int
    public let body: JSONValue?
    public let details: String?

    public init(
        _ message: String = "api request failed",
        statusCode: Int = 0,
        body: JSONValue? = nil,
        details: String? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.body = body
        self.details = details
    }
}

public struct ValidationError: VModalError {
    public let message: String
    public let statusCode: Int
    public let body: JSONValue?
    public let details: String?

    public init(
        _ message: String = "validation failed",
        statusCode: Int = 422,
        body: JSONValue? = nil,
        details: String? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.body = body
        self.details = details
    }
}

public struct FeatureDisabledError: VModalError {
    public let message: String
    public let statusCode = 0
    public let body: JSONValue? = nil
    public let details: String? = nil

    public init(_ message: String) { self.message = message }
}

public struct TransportError: VModalError {
    public let message = "transport error"
    public let statusCode = 0
    public let body: JSONValue? = nil
    public let details: String?

    public init(_ details: String? = nil) { self.details = details }
}

public struct ResponseTooLargeError: VModalError {
    public let message = "response exceeds the configured limit"
    public let statusCode = 0
    public let body: JSONValue? = nil
    public let details: String? = nil
    public let limitBytes: Int64
    public let observedBytes: Int64

    public init(limitBytes: Int64, observedBytes: Int64) {
        self.limitBytes = limitBytes
        self.observedBytes = observedBytes
    }
}

public struct MalformedResponseError: VModalError {
    public let message: String
    public let statusCode = 0
    public let body: JSONValue? = nil
    public let details: String? = nil

    public init(_ message: String = "malformed JSON response") { self.message = message }
}

public struct OperationCanceledError: VModalError {
    public let message = "operation canceled"
    public let statusCode = 0
    public let body: JSONValue? = nil
    public let details: String? = nil

    public init() {}
}
