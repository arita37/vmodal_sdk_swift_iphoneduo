import Foundation

public enum SDKMode: String, Codable, Sendable {
    case gateway
    case direct
}

private struct StaticAPIKeyProvider: APIKeyProvider {
    let key: String
    func current() async throws -> String { key }
}

public struct SDKConfig: Sendable, CustomStringConvertible {
    static let gatewayPath = Data(base64Encoded: "L2FwaS92MS9wcm94eS9zZWFyY2hfYXBp")!.withUnsafeBytes {
        String(decoding: $0, as: UTF8.self)
    }
    static let publicGateway = URL(string: String(
        decoding: Data(base64Encoded: "aHR0cHM6Ly9zZWFyY2hhcGktdGVzdC52LW1vZGFsLmNvbQ==")!,
        as: UTF8.self
    ))!
    static let devGateway = URL(string: String(
        decoding: Data(base64Encoded: "aHR0cDovLzEyNy4wLjAuMTozMDk5")!,
        as: UTF8.self
    ))!

    public let baseURL: URL
    public let userID: String?
    public let tenantID: String?
    public let email: String?
    public let requestTimeout: Duration
    public let responseIdleTimeout: Duration
    public let mode: SDKMode
    public let maxRetries: Int
    public let apiKeyProvider: any APIKeyProvider

    public init(
        baseURL: URL? = nil,
        userID: String? = nil,
        tenantID: String? = nil,
        email: String? = nil,
        token: String? = nil,
        apiKeyProvider: (any APIKeyProvider)? = nil,
        requestTimeout: Duration = .seconds(30),
        responseIdleTimeout: Duration? = nil,
        mode: SDKMode = .gateway,
        maxRetries: Int = 1
    ) throws {
        guard requestTimeout > .zero else { throw ValidationError("timeout must be positive") }
        let idle = responseIdleTimeout ?? requestTimeout
        guard idle > .zero else { throw ValidationError("idle_timeout must be positive") }
        guard maxRetries >= 0 else { throw ValidationError("max_retries must not be negative") }

        let rawURL = baseURL ?? Self.publicGateway
        self.baseURL = try Self.normalizeBaseURL(rawURL, mode: mode)
        self.userID = Self.trimmed(userID)
        self.tenantID = Self.trimmed(tenantID)
        self.email = Self.trimmed(email)
        self.requestTimeout = requestTimeout
        self.responseIdleTimeout = idle
        self.mode = mode
        self.maxRetries = maxRetries

        if let apiKeyProvider {
            self.apiKeyProvider = apiKeyProvider
        } else if let token {
            self.apiKeyProvider = StaticAPIKeyProvider(key: try validateAPIKey(token))
        } else if mode == .direct {
            self.apiKeyProvider = StaticAPIKeyProvider(key: "")
        } else {
            throw ValidationError("VMODAL_API_KEY is required")
        }
    }

    public static func fromEnvironment(
        _ env: [String: String],
        baseURL: URL? = nil,
        userID: String? = nil,
        tenantID: String? = nil,
        email: String? = nil,
        token: String? = nil,
        requestTimeout: Duration? = nil,
        responseIdleTimeout: Duration? = nil,
        mode: SDKMode = .gateway,
        maxRetries: Int? = nil,
        apiKeyProvider: (any APIKeyProvider)? = nil
    ) throws -> SDKConfig {
        let envName = (env["VMODAL_ENV"] ?? "prd").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard envName == "dev" || envName == "prd" else {
            throw ValidationError("VMODAL_ENV must be dev or prd")
        }
        let defaultURL = envName == "dev" ? devGateway : publicGateway
        let rawURL = baseURL ?? firstURL(env["VMODAL_BASE_URL"], env["TEST_CLIENT_SERVER_API_URL"]) ?? defaultURL
        let rawToken = token ?? first(
            env["VMODAL_API_KEY"], env["VMODAL_API_TOKEN"],
            env["TEST_CLIENT_CLERK_USER_API_TOKEN"], env["TEST_CLIENT_USER_TOKEN"]
        )
        let timeout = try requestTimeout ?? duration(env["VMODAL_TIMEOUT"], defaultValue: .seconds(30))
        let retries = maxRetries ?? Int(env["VMODAL_MAX_RETRIES"] ?? "") ?? 1
        return try SDKConfig(
            baseURL: rawURL,
            userID: userID ?? env["VMODAL_USER_ID"],
            tenantID: tenantID ?? env["VMODAL_TENANT_ID"],
            email: email ?? env["VMODAL_USER_EMAIL"],
            token: rawToken,
            apiKeyProvider: apiKeyProvider,
            requestTimeout: timeout,
            responseIdleTimeout: responseIdleTimeout,
            mode: mode,
            maxRetries: retries
        )
    }

    public var usersAPIBaseURL: URL {
        guard mode == .gateway else { return baseURL }
        var text = baseURL.absoluteString
        if text.hasSuffix(Self.gatewayPath) { text.removeLast(Self.gatewayPath.count) }
        return URL(string: text)!
    }

    public var description: String {
        "SDKConfig(baseURLConfigured=true, userIDConfigured=\(userID != nil), "
            + "tenantIDConfigured=\(tenantID != nil), emailConfigured=\(email != nil), "
            + "credentialConfigured=true, mode=\(mode.rawValue), maxRetries=\(maxRetries))"
    }

    func currentAPIKey() async throws -> String {
        try validateAPIKey(await apiKeyProvider.current())
    }

    static func normalizeBaseURL(_ url: URL, mode: SDKMode) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { throw ValidationError("invalid HTTP URL") }
        guard parts.user == nil, parts.password == nil else {
            throw ValidationError("URL user information is not allowed")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1"].contains(host)
        guard scheme == "https" || loopback else {
            throw ValidationError("HTTPS is required for non-local URLs")
        }
        parts.fragment = nil
        parts.query = nil
        while parts.path.count > 1 && parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path == "/" { parts.path = "" }
        if mode == .gateway && !parts.path.hasSuffix(gatewayPath) { parts.path += gatewayPath }
        guard let normalized = parts.url else { throw ValidationError("invalid HTTP URL") }
        return normalized
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func first(_ values: String?...) -> String? {
        values.compactMap(trimmed).first
    }

    private static func firstURL(_ values: String?...) -> URL? {
        for value in values {
            if let clean = trimmed(value), let url = URL(string: clean) { return url }
        }
        return nil
    }

    private static func duration(_ text: String?, defaultValue: Duration) throws -> Duration {
        guard let text, !text.isEmpty else { return defaultValue }
        guard let seconds = Double(text), seconds.isFinite else { return defaultValue }
        return .milliseconds(Int64((seconds * 1_000).rounded()))
    }
}
