import Foundation

/// Any JSON value: a record as stored, before it's decoded (or, later, decrypted) as a type, or
/// a record of a collection this version doesn't model. atproto has no floats, so whole numbers
/// stay exact.
///
/// It has its own parser and writer: decoding it with `Codable` means trying each JSON type in
/// turn, and going through `JSONSerialization` means bridging every value. Both were many times
/// slower than decoding the records themselves, which matters when listing a whole drive.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var array: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    /// This value decoded as a `T`, e.g. a record type.
    public func decode<T: Decodable>(as _: T.Type = T.self) throws -> T {
        try Self.shared.decoder.decode(T.self, from: serialized())
    }

    /// One for every call: making a decoder costs more than decoding a small record with it.
    /// Its options never change, and decoding doesn't change it, so it can be shared (whether
    /// or not the platform's SDK marks it `Sendable`).
    private struct SharedDecoder: @unchecked Sendable { let decoder = JSONDecoder() }
    private static let shared = SharedDecoder()

    /// A value's JSON form.
    public init(encoding value: some Encodable) throws {
        self = try JSONValue(parsing: JSONEncoder().encode(value))
    }

    // MARK: Reading

    public struct SyntaxError: Error, CustomStringConvertible {
        public var offset: Int
        public var description: String { "invalid JSON at byte \(offset)" }
    }

    /// Parses JSON text (RFC 8259).
    public init(parsing data: Data) throws {
        self = try data.withUnsafeBytes { buffer in
            var parser = Parser(bytes: buffer.bindMemory(to: UInt8.self))
            let value = try parser.value(depth: 0)
            parser.skipWhitespace()
            guard parser.index == parser.bytes.count else { throw SyntaxError(offset: parser.index) }
            return value
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        func fail() -> SyntaxError { SyntaxError(offset: index) }

        mutating func expect(_ literal: StaticString) throws {
            let count = literal.utf8CodeUnitCount
            guard index + count <= bytes.count else { throw fail() }
            for offset in 0..<count where bytes[index + offset] != literal.utf8Start[offset] { throw fail() }
            index += count
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw fail() }
            skipWhitespace()
            guard index < bytes.count else { throw fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var object: [String: JSONValue] = [:]
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(object)
                }
                while true {
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
                    let key = try string()
                    skipWhitespace()
                    try expect(":")
                    object[key] = try value(depth: depth + 1)
                    skipWhitespace()
                    guard index < bytes.count else { throw fail() }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "}") { return .object(object) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { throw fail() }
                }
            case UInt8(ascii: "["):
                index += 1
                var array: [JSONValue] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(array)
                }
                while true {
                    array.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard index < bytes.count else { throw fail() }
                    index += 1
                    if bytes[index - 1] == UInt8(ascii: "]") { return .array(array) }
                    guard bytes[index - 1] == UInt8(ascii: ",") else { throw fail() }
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default:
                return try number()
            }
        }

        mutating func number() throws -> JSONValue {
            let start = index
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digits = index
            scan: while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): break
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                    isInteger = false
                default: break scan
                }
                index += 1
            }
            guard index > digits else { throw fail() }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            if isInteger, let integer = Int64(text) { return .integer(integer) }
            guard let double = Double(text) else { throw fail() }
            return .number(double)
        }

        /// A string, starting at its opening quote.
        mutating func string() throws -> String {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
                index += 1
            }
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: "\"") {
                defer { index += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            }
            // Escapes: build it up.
            var utf8 = Array(bytes[start..<index])
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: utf8, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw fail() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                    case UInt8(ascii: "b"): utf8.append(0x08)
                    case UInt8(ascii: "f"): utf8.append(0x0C)
                    case UInt8(ascii: "n"): utf8.append(0x0A)
                    case UInt8(ascii: "r"): utf8.append(0x0D)
                    case UInt8(ascii: "t"): utf8.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800..<0xDC00).contains(scalar), index + 1 < bytes.count,
                            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                        {
                            let mark = index
                            index += 2
                            let low = try hex4()
                            if (0xDC00..<0xE000).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                index = mark
                            }
                        }
                        utf8 += Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8)
                    default:
                        throw fail()
                    }
                default:
                    utf8.append(byte)
                }
            }
            throw fail()
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail() }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw fail()
                }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }
    }

    // MARK: Writing

    /// The value as JSON text.
    public func serialized() -> Data {
        var out: [UInt8] = []
        write(to: &out)
        return Data(out)
    }

    private func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += "null".utf8
        case .bool(let value): out += (value ? "true" : "false").utf8
        case .integer(let value): out += String(value).utf8
        case .number(let value): out += (value.isFinite ? "\(value)" : "null").utf8
        case .string(let value): Self.write(value, to: &out)
        case .array(let values):
            out.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                value.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            for (index, (key, value)) in object.sorted(by: { $0.key < $1.key }).enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                Self.write(key, to: &out)
                out.append(UInt8(ascii: ":"))
                value.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func write(_ string: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out += #"\""#.utf8
            case UInt8(ascii: "\\"): out += #"\\"#.utf8
            case 0x0A: out += #"\n"#.utf8
            case 0x0D: out += #"\r"#.utf8
            case 0x09: out += #"\t"#.utf8
            case 0..<0x20:
                let hex = String(byte, radix: 16)
                out += ("\\u00" + (hex.count < 2 ? "0" + hex : hex)).utf8
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

extension JSONValue? {
    /// The value, unless it's absent or `null`.
    var unlessNull: JSONValue? {
        if case .some(.null) = self { nil } else { self }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        // Slow (see the type's comment): only for small things, like a saved unreadable record.
        // Bool before numbers: some decoders read `true` as 1.
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
