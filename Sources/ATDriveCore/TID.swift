import Foundation

/// A Timestamp Identifier: atproto's sortable 13-character record key.
/// Every file and folder gets one as its permanent ID, so renames and moves never change it.
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

    static func encode(_ value: UInt64, length: Int) -> String {
        var chars = [UInt8](repeating: alphabet[0], count: length)
        var remaining = value
        for index in stride(from: length - 1, through: 0, by: -1) {
            chars[index] = alphabet[Int(remaining & 31)]
            remaining >>= 5
        }
        return String(decoding: chars, as: UTF8.self)
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
