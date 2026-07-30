import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var intValue: Int64? {
        switch self {
        case let .integer(value): value
        case let .number(value) where value.isFinite && value.rounded() == value: Int64(exactly: value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

public enum CanonicalJSON {
    public enum Error: Swift.Error {
        case nonIntegralNumber
        case invalidString
    }

    public static func data<T: Encodable>(from value: T) throws -> Data {
        try data(from: JSONValue.from(value))
    }

    public static func data(from value: JSONValue) throws -> Data {
        var output = Data()
        try append(value, to: &output)
        return output
    }

    private static func append(_ value: JSONValue, to output: inout Data) throws {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case let .bool(value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case let .integer(value):
            guard value >= -9_007_199_254_740_991,
                  value <= 9_007_199_254_740_991 else { throw Error.nonIntegralNumber }
            output.append(contentsOf: String(value).utf8)
        case let .number(value):
            guard value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else {
                throw Error.nonIntegralNumber
            }
            output.append(contentsOf: String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value).utf8)
        case let .string(value):
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            )
            guard !data.isEmpty else { throw Error.invalidString }
            output.append(data)
        case let .array(values):
            output.append(UInt8(ascii: "["))
            for (index, item) in values.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try append(item, to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case let .object(values):
            output.append(UInt8(ascii: "{"))
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try append(.string(key), to: &output)
                output.append(UInt8(ascii: ":"))
                try append(values[key] ?? .null, to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }
}
