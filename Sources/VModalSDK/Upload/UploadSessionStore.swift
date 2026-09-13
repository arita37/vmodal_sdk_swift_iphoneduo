import CryptoKit
import Foundation

public protocol UploadSessionStore: Sendable {
    func load(_ key: String) async throws -> [String: JSONValue]?
    func save(_ key: String, value: [String: JSONValue]) async throws
    func remove(_ key: String) async throws
}

public actor MemoryUploadSessionStore: UploadSessionStore {
    private var values: [String: [String: JSONValue]] = [:]
    public init() {}
    public func load(_ key: String) -> [String: JSONValue]? { values[key] }
    public func save(_ key: String, value: [String: JSONValue]) { values[key] = value }
    public func remove(_ key: String) { values.removeValue(forKey: key) }
}

public actor FileUploadSessionStore: UploadSessionStore {
    public let directory: URL
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw TransportError("upload checkpoint path is invalid") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TransportError("upload checkpoint path is invalid")
        }
        self.directory = directory.standardizedFileURL
    }

    public func load(_ key: String) throws -> [String: JSONValue]? {
        let primary = file(key); let backup = primary.appendingPathExtension("bak")
        let source = FileManager.default.fileExists(atPath: primary.path) ? primary : (FileManager.default.fileExists(atPath: backup.path) ? backup : nil)
        guard let source else { return nil }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= checkpointLimitBytes else { throw ResponseTooLargeError(limitBytes: checkpointLimitBytes, observedBytes: Int64(size)) }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return try JSONValue.decodeObject(data)
    }

    public func save(_ key: String, value: [String: JSONValue]) throws {
        let data = try checkpointJSON(value)
        guard data.count <= checkpointLimitBytes else { throw ResponseTooLargeError(limitBytes: checkpointLimitBytes, observedBytes: Int64(data.count)) }
        let primary = file(key); let backup = primary.appendingPathExtension("bak")
        let temp = directory.appendingPathComponent(".\(primary.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .withoutOverwriting)
        do {
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            if FileManager.default.fileExists(atPath: primary.path) { try FileManager.default.moveItem(at: primary, to: backup) }
            try FileManager.default.moveItem(at: temp, to: primary)
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if !FileManager.default.fileExists(atPath: primary.path), FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: primary)
            }
            throw error
        }
    }

    public func remove(_ key: String) throws {
        let primary = file(key); let backup = primary.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: primary.path) { try FileManager.default.removeItem(at: primary) }
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
    }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}

func checkpointJSON(_ value: [String: JSONValue]) throws -> Data {
    let root = ["version", "contract", "request_id", "upload_id", "key", "part_count", "part_size_bytes", "part_md5"]
    let contract = [
        "protocol", "base_url", "user_id", "source_id", "source_version", "filename", "content_type",
        "size_bytes", "part_size_bytes", "mode", "group_name", "stream_name", "modality",
    ]
    guard Set(root).isSubset(of: value.keys), let contractValue = value["contract"]?.objectValue,
          let md5 = value["part_md5"]?.objectValue
    else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(value))
    }
    func encoded(_ item: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(item), as: UTF8.self)
    }
    let contractRows = try contract.map { key -> String in
        guard let item = contractValue[key] else { throw ValidationError("multipart checkpoint contract is incomplete") }
        return "\(try encoded(.string(key))):\(try encoded(item))"
    }
    let md5Rows = try md5.keys.sorted {
        (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1)
    }.map { key in "\(try encoded(.string(key))):\(try encoded(md5[key]!))" }
    var rows: [String] = []
    for key in root {
        let text: String
        if key == "contract" { text = "{\(contractRows.joined(separator: ","))}" }
        else if key == "part_md5" { text = "{\(md5Rows.joined(separator: ","))}" }
        else {
            guard let item = value[key] else { throw ValidationError("multipart checkpoint is incomplete") }
            text = try encoded(item)
        }
        rows.append("\(try encoded(.string(key))):\(text)")
    }
    return Data("{\(rows.joined(separator: ","))}".utf8)
}

public enum UploadSessionStores {
    public static let memory: any UploadSessionStore = MemoryUploadSessionStore()
}

func md5Hex(_ source: UploadSource, offset: Int64, length: Int64) async throws -> String {
    var digest = Insecure.MD5()
    for try await data in try source.open(offset: offset, length: length) { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
