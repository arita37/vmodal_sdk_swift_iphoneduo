import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Int64.self) { self = .int(value) }
        else if let value = try? box.decode(Double.self), value.isFinite { self = .double(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let value): try box.encode(value)
        case .int(let value): try box.encode(value)
        case .double(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(codingPath: box.codingPath, debugDescription: "non-finite JSON number"))
            }
            try box.encode(value)
        case .string(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value) where value.isFinite && value.rounded() == value: return Int(exactly: value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value.isFinite ? value : nil
        case .string(let value):
            guard let number = Double(value), number.isFinite else { return nil }
            return number
        default: return nil
        }
    }
}

extension JSONValue {
    static func decodeObject(_ data: Data) throws -> [String: JSONValue] {
        guard !data.isEmpty else { return [:] }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let object) = value else { throw MalformedResponseError() }
            return object
        } catch let error as MalformedResponseError {
            throw error
        } catch {
            throw MalformedResponseError()
        }
    }
}
