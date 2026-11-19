import Foundation

/// The part of TOML that `config.toml` needs, read and also edited in place: setting one value
/// changes only that value, so the comments and layout someone gave their file survive the Mac
/// app saving a setting.
///
/// Supported: comments, `[table]` and `[table.sub]` headers, bare and dotted keys, strings
/// (basic and literal, one line), integers, floats, booleans, and arrays of strings (over several
/// lines if need be, with comments and a trailing comma). Anything else (other arrays, inline
/// tables, dates, multi-line strings, quoted keys) is reported as unsupported rather than
/// misread. None of our settings need them yet.
struct TOMLDocument: Sendable {
    enum Value: Sendable, Equatable, CustomStringConvertible {
        case string(String)
        case integer(Int)
        case float(Double)
        case boolean(Bool)
        case strings([String])

        /// As TOML, on one line.
        var description: String {
            switch self {
            case .integer(let value): String(value)
            case .boolean(let value): String(value)
            case .float(let value):
                value.isNaN ? "nan" : value.isInfinite ? (value < 0 ? "-inf" : "inf") : "\(value)"
            case .string(let value): Self.quoted(value)
            case .strings(let values): "[" + values.map(Self.quoted).joined(separator: ", ") + "]"
            }
        }

        /// As TOML, as it's written in the file: a non-empty array one item per line.
        var fileText: String {
            guard case .strings(let values) = self, !values.isEmpty else { return description }
            return "[\n" + values.map { "  \(Self.quoted($0)),\n" }.joined() + "]"
        }

        private static func quoted(_ value: String) -> String {
            "\"" + value.unicodeScalars.map(escape).joined() + "\""
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
        /// 0-based: where the key is, and the line the value ends on.
        var line: Int
        var endLine: Int
        var value: Value
        /// Where the value is in the text (`body`), in characters.
        var range: Range<Int>
    }

    /// The text, its lines joined by "\n" whatever the file uses.
    private var body: [Character]
    private let lineEnding: String
    /// By full dotted key (`sync.interval`), whichever way the file spelled it.
    private(set) var entries: [String: Entry] = [:]
    /// Table headers' lines, by name.
    private var tables: [String: Int] = [:]

    init(parsing text: String) throws(TOMLError) {
        // By Unicode scalar: as Characters, "\r\n" is one, and isn't "\n".
        var scalars = String.UnicodeScalarView()
        var crlf = false
        var pendingReturn = false
        for scalar in text.unicodeScalars {
            if pendingReturn {
                pendingReturn = false
                if scalar == "\n" {
                    crlf = true
                    scalars.append("\n")
                    continue
                }
                scalars.append("\r")
            }
            if scalar == "\r" {
                pendingReturn = true
            } else {
                scalars.append(scalar)
            }
        }
        if pendingReturn { scalars.append("\r") }
        body = Array(String(scalars))
        lineEnding = crlf ? "\r\n" : "\n"

        var parser = Parser(body)
        var table = ""
        while let statement = try parser.next() {
            switch statement {
            case .table(let name, let line):
                guard tables[name] == nil else { throw TOMLError(line: line + 1, "[\(name)] appears twice") }
                tables[name] = line
                table = name
            case .entry(let key, let value, let range, let line, let endLine):
                let full = table.isEmpty ? key : "\(table).\(key)"
                guard entries[full] == nil else { throw TOMLError(line: line + 1, "\(full) is set twice") }
                entries[full] = Entry(line: line, endLine: endLine, value: value, range: range)
            }
        }
    }

    var text: String {
        let joined = String(body)
        return lineEnding == "\n" ? joined : joined.replacingOccurrences(of: "\n", with: lineEnding)
    }

    func value(_ key: String) -> Value? { entries[key]?.value }

    /// Sets `key` (dotted, e.g. `sync.interval`): in place where it's already set, under its
    /// table where that exists, or in a new table at the end.
    mutating func set(_ key: String, to value: Value) {
        let rendered = value.fileText
        if let entry = entries[key] {
            body.replaceSubrange(entry.range, with: Array(rendered))
        } else {
            var lines = String(body).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let parts = key.split(separator: ".")
            let table = parts.dropLast().joined(separator: ".")
            let line = "\(parts.last!) = \(rendered)"
            if table.isEmpty || tables[table] != nil {
                // After the last thing set in that table (or its header; the top of the file
                // for a key outside any table).
                let start = table.isEmpty ? -1 : tables[table]!
                let end = tables.values.filter { $0 > start }.min() ?? lines.count
                let last = entries.values.map(\.endLine).filter { $0 > start && $0 < end }.max() ?? start
                lines.insert(line, at: last + 1)
            } else {
                let endsWithNewline = lines.last == ""
                if endsWithNewline { lines.removeLast() }
                if let previous = lines.last, !previous.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines += ["[\(table)]", line, ""]
            }
            body = Array(lines.joined(separator: "\n"))
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

/// Reads a TOML text one statement (a table header or a key = value) at a time.
private struct Parser {
    enum Statement {
        case table(String, line: Int)
        case entry(key: String, value: TOMLDocument.Value, range: Range<Int>, line: Int, endLine: Int)
    }

    let characters: [Character]
    var index = 0
    /// 0-based, where `index` is.
    var line = 0

    init(_ characters: [Character]) {
        self.characters = characters
    }

    var current: Character? { index < characters.count ? characters[index] : nil }

    func error(_ message: String) -> TOMLError { TOMLError(line: line + 1, message) }

    func unsupported(_ what: String) -> TOMLError { error("\(what) aren't supported in ATDrive's config.toml") }

    mutating func advance() {
        if current == "\n" { line += 1 }
        index += 1
    }

    /// The next statement; `nil` at the end.
    mutating func next() throws(TOMLError) -> Statement? {
        while true {
            skipSpace()
            switch current {
            case nil: return nil
            case "\n": advance()
            case "#": skipComment()
            default:
                let statement = try statement()
                skipSpace()
                if current == "#" { skipComment() }
                if let extra = current, extra != "\n" { throw error("unexpected \(extra)") }
                return statement
            }
        }
    }

    mutating func statement() throws(TOMLError) -> Statement {
        let start = line
        if current == "[" {
            advance()
            if current == "[" { throw unsupported("arrays of tables ([[…]])") }
            skipSpace()
            let name = try key()
            skipSpace()
            guard current == "]" else { throw error("expected ] after the table name") }
            advance()
            return .table(name, line: start)
        }
        let name = try key()
        skipSpace()
        guard current == "=" else { throw error("expected = after \(name)") }
        advance()
        skipSpace()
        let from = index
        let value = try value()
        return .entry(key: name, value: value, range: from..<index, line: start, endLine: line)
    }

    mutating func skipSpace() {
        while current == " " || current == "\t" { advance() }
    }

    mutating func skipComment() {
        while let character = current, character != "\n" { advance() }
    }

    /// Spaces, line breaks and comments: what may come between an array's items.
    mutating func skipBlank() {
        while true {
            skipSpace()
            if current == "\n" {
                advance()
            } else if current == "#" {
                skipComment()
            } else {
                return
            }
        }
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
            while let character = current, Self.isBare(character) { advance() }
            guard index > start else { throw error("expected a key") }
            parts.append(String(characters[start..<index]))
            skipSpace()
            guard current == "." else { return parts.joined(separator: ".") }
            advance()
            skipSpace()
        }
    }

    mutating func value() throws(TOMLError) -> TOMLDocument.Value {
        switch current {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": return .strings(try strings())
        case "{": throw unsupported("inline tables")
        case nil, "\n": throw error("expected a value")
        default: break
        }
        let start = index
        while let character = current, character != " ", character != "\t", character != "#", character != "\n",
            character != ",", character != "]"
        {
            advance()
        }
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

    /// `[ "a", 'b', ]`, over as many lines as it takes.
    mutating func strings() throws(TOMLError) -> [String] {
        advance()
        var items: [String] = []
        while true {
            skipBlank()
            switch current {
            case "]":
                advance()
                return items
            case "\"": items.append(try basicString())
            case "'": items.append(try literalString())
            case nil: throw error("the array isn't closed (no ])")
            default: throw unsupported("arrays of anything but text")
            }
            skipBlank()
            switch current {
            case ",": advance()
            case "]":
                advance()
                return items
            default: throw error("expected , or ] after an item in the array")
            }
        }
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
        advance()
        if current == "\"", index + 1 < characters.count, characters[index + 1] == "\"" {
            throw unsupported("multi-line strings")
        }
        var text = ""
        while let character = current, character != "\n" {
            advance()
            switch character {
            case "\"": return text
            case "\\":
                guard let escaped = current, escaped != "\n" else { break }
                advance()
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
                    for _ in 0..<count { advance() }
                    text.unicodeScalars.append(scalar)
                default: throw error("unknown escape \\\(escaped)")
                }
            default: text.append(character)
            }
        }
        throw error("the string isn't closed (no \" before the end of the line)")
    }

    mutating func literalString() throws(TOMLError) -> String {
        advance()
        if current == "'", index + 1 < characters.count, characters[index + 1] == "'" {
            throw unsupported("multi-line strings")
        }
        let start = index
        while let character = current, character != "'", character != "\n" { advance() }
        guard current == "'" else { throw error("the string isn't closed (no ' before the end of the line)") }
        advance()
        return String(characters[start..<index - 1])
    }
}
