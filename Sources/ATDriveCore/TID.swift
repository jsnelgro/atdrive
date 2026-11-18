import Foundation

/// A Timestamp Identifier: atproto's sortable 13-character record key.
/// Every file and folder gets one as its permanent ID, so renames and moves never change it.
/// Every version gets one too, and it says when the change was made.
/// https://atproto.com/specs/tid
public enum TID {
    private static let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz".utf8)
    private static let clock = Clock()

    /// A new TID, strictly greater than any other this process has generated.
    public static func next() -> String {
        let (micros, clockID) = clock.tick()
        return encode(micros, length: 11) + encode(clockID, length: 2)
    }

    public static func isValid(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 13, alphabet[0..<16].contains(bytes[0]) else { return false }
        return bytes.allSatisfy(alphabet.contains)
    }

    /// When a TID was made (to the microsecond), or `nil` if it isn't one.
    public static func date(_ tid: String) -> Date? {
        guard isValid(tid), let micros = decode(tid.utf8.prefix(11)) else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    /// The smallest TID for a moment: every TID made at `date` or later sorts after it, and
    /// every one made earlier sorts before it.
    public static func lowest(at date: Date) -> String {
        encode(micros(date), length: 11) + encode(0, length: 2)
    }

    /// The largest TID for a moment: every TID made at `date` or earlier sorts before (or is)
    /// it, and every one made later sorts after it.
    public static func highest(at date: Date) -> String {
        encode(micros(date), length: 11) + encode(1023, length: 2)
    }

    static func make(micros: UInt64, clockID: UInt64) -> String {
        encode(micros, length: 11) + encode(clockID, length: 2)
    }

    static func micros(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
    }

    static func encode(_ value: UInt64, length: Int) -> String {
        var chars = [UInt8](repeating: alphabet[0], count: length)
        var remaining = value
        for index in stride(from: length - 1, through: 0, by: -1) {
            chars[index] = alphabet[Int(remaining & 31)]
            remaining >>= 5
        }
        return String(decoding: chars, as: UTF8.self)
    }

    private static func decode(_ chars: some Sequence<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        for char in chars {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            value = value << 5 | UInt64(digit)
        }
        return value
    }

    /// Microsecond clock that never goes backwards or repeats within this process.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64 = 0
        private let clockID = UInt64.random(in: 0..<1024)

        func tick() -> (UInt64, UInt64) {
            lock.lock()
            defer { lock.unlock() }
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            last = max(now, last + 1)
            return (last, clockID)
        }
    }
}

/// Where a `Drive` gets new IDs: the system clock (`TID.next`), or a clock of the caller's, so
/// tests can make history at chosen times without waiting. IDs never go backwards or repeat.
public final class TIDSource: @unchecked Sendable {
    /// The system clock, shared by the whole process.
    public static let system = TIDSource()

    private let now: (@Sendable () -> Date)?
    private let clockID: UInt64
    private let lock = NSLock()
    private var last: UInt64 = 0

    private init() {
        now = nil
        clockID = 0
    }

    /// TIDs at the times `now` gives (strictly increasing, even if it stands still).
    public init(clockID: UInt64 = .random(in: 0..<1024), now: @escaping @Sendable () -> Date) {
        self.now = now
        self.clockID = clockID % 1024
    }

    public func next() -> String {
        guard let now else { return TID.next() }
        lock.lock()
        defer { lock.unlock() }
        last = max(TID.micros(now()), last + 1)
        return TID.make(micros: last, clockID: clockID)
    }
}
