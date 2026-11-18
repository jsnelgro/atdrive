import Foundation

/// The part of TOML that `config.toml` needs, read and also edited in place: setting one value
/// changes only that value, so the comments and layout someone gave their file survive the Mac
/// app saving a setting.
///
/// Supported: comments, `[table]` and `[table.sub]` headers, bare and dotted keys, and strings
/// (basic and literal, one line), integers, floats and booleans. Anything else (arrays, inline
/// tables, dates, multi-line strings, quoted keys) is reported as unsupported rather than
/// misread. None of our settings need them yet.
struct TOMLDocument: Sendable {
    enum Value: Sendable, Equatable, CustomStringConvertible {
        case string(String)
        case integer(Int)
        case float(Double)
        case boolean(Bool)

        /// As TOML.
        var description: String {
            switch self {
            case .integer(let value): String(value)
            case .boolean(let value): String(value)
            case .float(let value):
                value.isNaN ? "nan" : value.isInfinite ? (value < 0 ? "-inf" : "inf") : "\(value)"
            case .string(let value):
                "\"" + value.unicodeScalars.map(Self.escape).joined() + "\""
            }
        }

        private static func escape(_ scalar: Unicode.Scalar) -> String {
            switch scalar {
            case "\"": "\\\""
            case "\\": "\\\\"
            case "\n": "\\n"
            case "\t": "\\t"
            case "\r": "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                String(format: "\\u%04X", scalar.value)
            default: String(scalar)
            }
        }
    }

    struct Entry: Sendable {
        /// 0-based.
        var line: Int
        var value: Value
        /// Where the value is in its line, in characters.
        var range: Range<Int>
    }

    /// Without their line endings.
    private(set) var lines: [String]
    private let lineEnding: String
    /// By full dotted key (`sync.interval`), whichever way the file spelled it.
    private(set) var entries: [String: Entry] = [:]
    /// Table headers' lines, by name.
    private var tables: [String: Int] = [:]

    init(parsing text: String) throws(TOMLError) {
        // By Unicode scalar: as Characters, "\r\n" is one, and isn't "\n".
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var crlf = false
        for scalar in text.unicodeScalars {
            guard scalar == "\n" else {
                line.append(scalar)
                continue
            }
            if line.last == "\r" {
                line.removeLast()
                crlf = true
            }
            lines.append(String(line))
            line = String.UnicodeScalarView()
        }
        lines.append(String(line))
        self.lines = lines
        lineEnding = crlf ? "\r\n" : "\n"
        var table = ""
        for (number, line) in lines.enumerated() {
            var parser = LineParser(Array(line), line: number + 1)
            switch try parser.parse() {
            case .nothing:
                break
            case .table(let name):
                guard tables[name] == nil else { throw TOMLError(line: number + 1, "[\(name)] appears twice") }
                tables[name] = number
                table = name
            case .entry(let key, let value, let range):
                let full = table.isEmpty ? key : "\(table).\(key)"
                guard entries[full] == nil else { throw TOMLError(line: number + 1, "\(full) is set twice") }
                entries[full] = Entry(line: number, value: value, range: range)
            }
        }
    }

    var text: String { lines.joined(separator: lineEnding) }

    func value(_ key: String) -> Value? { entries[key]?.value }

    /// Sets `key` (dotted, e.g. `sync.interval`): in place where it's already set, under its
    /// table where that exists, or in a new table at the end.
    mutating func set(_ key: String, to value: Value) {
        let rendered = value.description
        if let entry = entries[key] {
            var characters = Array(lines[entry.line])
            characters.replaceSubrange(entry.range, with: Array(rendered))
            lines[entry.line] = String(characters)
        } else {
            let parts = key.split(separator: ".")
            let table = parts.dropLast().joined(separator: ".")
            let line = "\(parts.last!) = \(rendered)"
            if table.isEmpty || tables[table] != nil {
                // After the last thing set in that table (or its header; the top of the file
                // for a key outside any table).
                let start = table.isEmpty ? -1 : tables[table]!
                let end = tables.values.filter { $0 > start }.min() ?? lines.count
                let last = entries.values.map(\.line).filter { $0 > start && $0 < end }.max() ?? start
                lines.insert(line, at: last + 1)
            } else {
                let endsWithNewline = lines.last == ""
                if endsWithNewline { lines.removeLast() }
                if let previous = lines.last, !previous.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines += ["[\(table)]", line, ""]
            }
        }
        // Positions after the edit; the text is still valid, having just been.
        self = try! TOMLDocument(parsing: text)
    }
}

struct TOMLError: Error, Equatable, CustomStringConvertible {
    /// 1-based.
    let line: Int
    let message: String

    init(line: Int, _ message: String) {
        self.line = line
        self.message = message
    }

    var description: String { "line \(line): \(message)" }
}

/// One line of a TOML file.
private struct LineParser {
    enum Result {
        case nothing
        case table(String)
        case entry(key: String, value: TOMLDocument.Value, range: Range<Int>)
    }

    let characters: [Character]
    let line: Int
    var index = 0

    init(_ characters: [Character], line: Int) {
        self.characters = characters
        self.line = line
    }

    var current: Character? { index < characters.count ? characters[index] : nil }

    func error(_ message: String) -> TOMLError { TOMLError(line: line, message) }

    func unsupported(_ what: String) -> TOMLError { error("\(what) aren't supported in ATDrive's config.toml") }

    mutating func parse() throws(TOMLError) -> Result {
        skipSpace()
        guard let first = current, first != "#" else { return .nothing }
        let result: Result
        if first == "[" {
            index += 1
            if current == "[" { throw unsupported("arrays of tables ([[…]])") }
            skipSpace()
            let name = try key()
            skipSpace()
            guard current == "]" else { throw error("expected ] after the table name") }
            index += 1
            result = .table(name)
        } else {
            let name = try key()
            skipSpace()
            guard current == "=" else { throw error("expected = after \(name)") }
            index += 1
            skipSpace()
            let start = index
            let value = try value()
            result = .entry(key: name, value: value, range: start..<index)
        }
        skipSpace()
        if let extra = current, extra != "#" { throw error("unexpected \(extra)") }
        return result
    }

    mutating func skipSpace() {
        while current == " " || current == "\t" { index += 1 }
    }

    static func isBare(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    /// A bare key, or several joined with dots.
    mutating func key() throws(TOMLError) -> String {
        var parts: [String] = []
        while true {
            if current == "\"" || current == "'" { throw unsupported("quoted keys") }
            let start = index
            while let character = current, Self.isBare(character) { index += 1 }
            guard index > start else { throw error("expected a key") }
            parts.append(String(characters[start..<index]))
            skipSpace()
            guard current == "." else { return parts.joined(separator: ".") }
            index += 1
            skipSpace()
        }
    }

    mutating func value() throws(TOMLError) -> TOMLDocument.Value {
        switch current {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": throw unsupported("arrays")
        case "{": throw unsupported("inline tables")
        case nil: throw error("expected a value")
        default: break
        }
        let start = index
        while let character = current, character != " ", character != "\t", character != "#" { index += 1 }
        let token = String(characters[start..<index])
        switch token {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if let number = Self.number(token) { return number }
        if token.first?.isNumber == true, token.contains("-") || token.contains(":") {
            throw unsupported("dates and times")
        }
        if token.hasPrefix("0x") || token.hasPrefix("0o") || token.hasPrefix("0b") {
            throw unsupported("hexadecimal, octal and binary numbers")
        }
        throw error("\(token) isn't a value (text goes in quotes: \"\(token)\")")
    }

    /// A decimal integer or float, as TOML spells them (`_` between digits, no leading zeros).
    static func number(_ token: String) -> TOMLDocument.Value? {
        var rest = Substring(token)
        let sign = rest.first == "+" || rest.first == "-" ? String(rest.removeFirst()) : ""
        func digits(_ text: Substring) -> String? {
            guard let first = text.first, let last = text.last, first.isASCII, first.isNumber, last.isNumber,
                !text.contains("__"), text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "_" })
            else { return nil }
            return text.replacingOccurrences(of: "_", with: "")
        }
        let exponentAt = rest.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = rest[..<(exponentAt ?? rest.endIndex)]
        let pointAt = mantissa.firstIndex(of: ".")
        guard let whole = digits(mantissa[..<(pointAt ?? mantissa.endIndex)]),
            whole == "0" || !whole.hasPrefix("0")
        else { return nil }
        var fraction = ""
        if let pointAt {
            guard let part = digits(mantissa[mantissa.index(after: pointAt)...]) else { return nil }
            fraction = "." + part
        }
        var exponent = ""
        if let exponentAt {
            var part = rest[rest.index(after: exponentAt)...]
            let exponentSign = part.first == "+" || part.first == "-" ? String(part.removeFirst()) : ""
            guard let value = digits(part) else { return nil }
            exponent = "e" + exponentSign + value
        }
        if fraction.isEmpty && exponent.isEmpty {
            return Int(sign + whole).map { .integer($0) }
        }
        return Double(sign + whole + fraction + exponent).map { .float($0) }
    }

    mutating func basicString() throws(TOMLError) -> String {
        index += 1
        if current == "\"", index + 1 < characters.count, characters[index + 1] == "\"" {
            throw unsupported("multi-line strings")
        }
        var text = ""
        while let character = current {
            index += 1
            switch character {
            case "\"": return text
            case "\\":
                guard let escaped = current else { break }
                index += 1
                switch escaped {
                case "\"": text.append("\"")
                case "\\": text.append("\\")
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "b": text.append("\u{8}")
                case "f": text.append("\u{C}")
                case "u", "U":
                    let count = escaped == "u" ? 4 : 8
                    guard index + count <= characters.count,
                        let code = UInt32(String(characters[index..<index + count]), radix: 16),
                        let scalar = Unicode.Scalar(code)
                    else { throw error("bad \\\(escaped) escape") }
                    index += count
                    text.unicodeScalars.append(scalar)
                default: throw error("unknown escape \\\(escaped)")
                }
            default: text.append(character)
            }
        }
        throw error("the string isn't closed (no \" before the end of the line)")
    }

    mutating func literalString() throws(TOMLError) -> String {
        index += 1
        if current == "'", index + 1 < characters.count, characters[index + 1] == "'" {
            throw unsupported("multi-line strings")
        }
        let start = index
        while let character = current, character != "'" { index += 1 }
        guard current == "'" else { throw error("the string isn't closed (no ' before the end of the line)") }
        index += 1
        return String(characters[start..<index - 1])
    }
}
