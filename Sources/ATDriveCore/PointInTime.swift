import Foundation

/// A moment typed on the command line (`--at <when>`), to see or restore the drive as it was:
/// - How long ago: `2h`, `30m`, `3d`. Units are `s`, `m`, `h`, `d` and `w`, and can be combined
///   (`1h30m`). A day is 24 hours.
/// - A day: `2026-11-08`, from the start of that day in local time.
/// - A time: `2026-11-08T14:00` (or with seconds, or a space for the `T`), in local time unless
///   it ends with an offset (`Z`, `+01:00`, `-0500`).
/// - A version ID (a TID, from `atdrive history`): just after that change.
public enum PointInTime {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// Not a time this understands, or a day or time that doesn't exist.
        case invalid(String)
        /// A day or time after now.
        case future(String)

        public var description: String {
            switch self {
            case .invalid(let text): "\"\(text)\" isn't a time: \(reason)"
            case .future(let text): "\(text) is in the future"
            }
        }

        /// What's wrong, without repeating the text.
        public var reason: String {
            switch self {
            case .invalid: "use 2h or 3d (ago), 2026-11-08, 2026-11-08T14:00, or a version ID"
            case .future: "that's in the future"
            }
        }
    }

    /// The moment `text` names. Days and times without an offset are in `timeZone`. A day or a
    /// time after `now` is an error: the drive can't be seen as it will be.
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> Date {
        let text = text.trimmingCharacters(in: .whitespaces)
        if TID.isValid(text), let date = TID.date(text) { return date }
        if let seconds = try duration(text) { return now.addingTimeInterval(-seconds) }
        guard let date = calendarDate(text, timeZone: timeZone) else { throw ParseError.invalid(text) }
        if date > now { throw ParseError.future(text) }
        return date
    }

    // MARK: How long ago

    private static let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604_800]

    /// Seconds for `2h`, `1h30m` and the like; `nil` if `text` doesn't look like a duration at
    /// all (it doesn't start with a digit, or it's a date).
    private static func duration(_ text: String) throws -> TimeInterval? {
        guard let first = text.first, first.isASCII, first.isNumber, !text.contains("-"), !text.contains(":") else {
            return nil
        }
        var total = 0.0
        var digits = ""
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if let unit = units[character], !digits.isEmpty, let value = Int(digits) {
                total += Double(value) * unit
                digits = ""
            } else {
                throw ParseError.invalid(text)
            }
        }
        // A number with no unit (`2`), or a value too big to be a time.
        guard digits.isEmpty, total < 1e12 else { throw ParseError.invalid(text) }
        return total
    }

    // MARK: Days and times

    /// `2026-11-08`, `2026-11-08T14:00`, `2026-11-08 14:00:30`, `2026-11-08T14:00Z`,
    /// `2026-11-08T14:00:00.5+01:00`; `nil` if it isn't one of those, or names a day or time that
    /// doesn't exist.
    private static func calendarDate(_ text: String, timeZone: TimeZone) -> Date? {
        var scanner = Scanner(Array(text.utf8))
        guard let year = scanner.number(digits: 4), scanner.skip("-"), let month = scanner.number(digits: 2),
            scanner.skip("-"), let day = scanner.number(digits: 2)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Noon is in the day whatever the clocks do at midnight, so it checks the day exists.
        guard (1...12).contains(month), (1...31).contains(day),
            let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: noon)
        guard check.year == year, check.month == month, check.day == day else { return nil }  // say Feb 30
        if scanner.atEnd { return calendar.startOfDay(for: noon) }

        guard scanner.skip("T") || scanner.skip("t") || scanner.skip(" "), let hour = scanner.number(digits: 2),
            scanner.skip(":"), let minute = scanner.number(digits: 2), hour < 24, minute < 60
        else { return nil }
        var second = 0
        var fraction = 0.0
        if scanner.skip(":") {
            guard let value = scanner.number(digits: 2), value < 60 else { return nil }
            second = value
            if scanner.skip(".") {
                guard let digits = scanner.digits(), let value = Double("0." + digits) else { return nil }
                fraction = value
            }
        }
        if !scanner.atEnd {
            guard let offset = scanner.offset(), scanner.atEnd, let zone = TimeZone(secondsFromGMT: offset) else {
                return nil
            }
            calendar.timeZone = zone
        }
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }

    /// Reads ASCII text left to right.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index == bytes.count }

        mutating func skip(_ character: Character) -> Bool {
            guard !atEnd, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }

        /// Exactly `count` digits.
        mutating func number(digits count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[index..<index + count] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            index += count
            return value
        }

        /// One or more digits, as text.
        mutating func digits() -> String? {
            let start = index
            while !atEnd, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index > start ? String(decoding: bytes[start..<index], as: UTF8.self) : nil
        }

        /// `Z`, `+01:00`, `+0100` or `+01` (or `-`), in seconds east of UTC.
        mutating func offset() -> Int? {
            if skip("Z") || skip("z") { return 0 }
            let sign: Int
            if skip("+") {
                sign = 1
            } else if skip("-") {
                sign = -1
            } else {
                return nil
            }
            guard let hours = number(digits: 2), hours <= 18 else { return nil }
            var minutes = 0
            if !atEnd {
                _ = skip(":")
                guard let value = number(digits: 2), value < 60 else { return nil }
                minutes = value
            }
            return sign * (hours * 3600 + minutes * 60)
        }
    }
}
