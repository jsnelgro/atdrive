import Foundation
import Testing

@testable import ATDriveCore

/// `--at <when>`: how long ago, a day, a time, or a version ID.
@Suite struct PointInTimeTests {
    /// 2026-11-10 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_312_000)
    static let paris = TimeZone(identifier: "Europe/Paris")!

    func parse(_ text: String, in zone: TimeZone = PointInTimeTests.paris) throws -> Date {
        try PointInTime.parse(text, now: Self.now, timeZone: zone)
    }

    /// A UTC time, as `yyyy-MM-ddTHH:mm:ss`.
    func utc(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test func nowIsWhatTheTestsThinkItIs() {
        #expect(utc("2026-11-10T12:00:00") == Self.now)
    }

    @Test func howLongAgo() throws {
        #expect(try parse("2h") == Self.now - 2 * 3600)
        #expect(try parse("30m") == Self.now - 30 * 60)
        #expect(try parse("3d") == Self.now - 3 * 86400)
        #expect(try parse("45s") == Self.now - 45)
        #expect(try parse("1w") == Self.now - 7 * 86400)
        #expect(try parse("1h30m") == Self.now - 5400)
        #expect(try parse("1d12h") == Self.now - 36 * 3600)
        #expect(try parse("0m") == Self.now)
        #expect(try parse(" 2h ") == Self.now - 2 * 3600)
        #expect(try parse("90m") == Self.now - 90 * 60)  // no need to carry into hours
    }

    @Test func aDayStartsAtMidnightLocalTime() throws {
        #expect(try parse("2026-11-08") == utc("2026-11-07T23:00:00"))  // Paris is UTC+1 in November
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(try parse("2026-11-08", in: losAngeles) == utc("2026-11-08T08:00:00"))
        #expect(try parse("2026-07-01") == utc("2026-06-30T22:00:00"))  // summer time: UTC+2
        #expect(try parse("2024-02-29") == utc("2024-02-28T23:00:00"))  // a leap day
        #expect(try parse("2026-11-10") == utc("2026-11-09T23:00:00"))  // today: its start has passed
    }

    /// Where clocks skip midnight, the day starts at 1:00. Cuba moves to summer time at 0:00 on
    /// the second Sunday in March.
    @Test func aDayWhoseMidnightIsSkipped() throws {
        let havana = try #require(TimeZone(identifier: "America/Havana"))
        #expect(try parse("2026-03-08", in: havana) == utc("2026-03-08T05:00:00"))  // 1:00 CDT
        #expect(try parse("2026-03-07", in: havana) == utc("2026-03-07T05:00:00"))  // 0:00 CST
    }

    @Test func aTimeIsLocalUnlessItHasAnOffset() throws {
        #expect(try parse("2026-11-08T14:00") == utc("2026-11-08T13:00:00"))
        #expect(try parse("2026-11-08 14:00") == utc("2026-11-08T13:00:00"))
        #expect(try parse("2026-11-08t14:00") == utc("2026-11-08T13:00:00"))
        #expect(try parse("2026-11-08T14:00:30") == utc("2026-11-08T13:00:30"))
        #expect(try parse("2026-11-08T00:00") == utc("2026-11-07T23:00:00"))
        #expect(try parse("2026-11-08T23:59:59") == utc("2026-11-08T22:59:59"))

        #expect(try parse("2026-11-08T14:00Z") == utc("2026-11-08T14:00:00"))
        #expect(try parse("2026-11-08T14:00:00z") == utc("2026-11-08T14:00:00"))
        #expect(try parse("2026-11-08T14:00:00+01:00") == utc("2026-11-08T13:00:00"))
        #expect(try parse("2026-11-08T14:00-0530") == utc("2026-11-08T19:30:00"))
        #expect(try parse("2026-11-08T14:00+09") == utc("2026-11-08T05:00:00"))
        #expect(try parse("2026-11-08T14:00:00.250Z") == utc("2026-11-08T14:00:00") + 0.25)
    }

    @Test func aVersionID() throws {
        let when = Date(timeIntervalSince1970: 1_794_000_000.123456)
        let id = TID.make(micros: TID.micros(when), clockID: 7)
        let parsed = try parse(id)
        #expect(abs(parsed.timeIntervalSince(when)) < 0.000_01)
        #expect(parsed == TID.date(id))
        // Just after the change: the drive as of then includes it.
        #expect(id <= TID.highest(at: parsed))
    }

    @Test func notTimes() {
        for text in [
            "", " ", "2", "h", "2x", "2H", "2M", "-2h", "+2h", "1.5h", "2h2", "2 h", "h2", "2hh",
            "99999999999999999999d", "9999999999999w",
            "2026", "2026-11", "2026-11-8", "26-11-08", "2026/11/08", "2026-13-01", "2026-00-10", "2026-02-29",
            "2026-02-30", "2026-04-31", "2026-11-00", "2026-11-32", "2026-11-08T", "2026-11-08T14",
            "2026-11-08T1400", "2026-11-08T24:00", "2026-11-08T14:60", "2026-11-08T14:00:60", "2026-11-08T14:00:",
            "2026-11-08T14:00:00.", "2026-11-08T14:00+", "2026-11-08T14:00+1", "2026-11-08T14:00+19:00",
            "2026-11-08T14:00+01:60", "2026-11-08T14:00Zjunk", "2026-11-08Z", "2026-11-08x", "yesterday",
            "3jzfcijpj2z2", "3JZFCIJPJ2Z2A",
        ] {
            #expect(throws: PointInTime.ParseError.self, "\(text)") { try parse(text) }
        }
    }

    @Test func notInTheFuture() throws {
        #expect(throws: PointInTime.ParseError.future("2026-11-11")) { try parse("2026-11-11") }
        #expect(throws: PointInTime.ParseError.future("2026-11-10T12:00:01Z")) { try parse("2026-11-10T12:00:01Z") }
        #expect(try parse("2026-11-10T12:00:00Z") == Self.now)
    }

    @Test func theErrorSaysWhatWorks() {
        #expect(throws: PointInTime.ParseError.invalid("2x")) { try parse(" 2x ") }
        #expect(
            PointInTime.ParseError.invalid("2x").description
                == "\"2x\" isn't a time: use 2h or 3d (ago), 2026-11-08, 2026-11-08T14:00, or a version ID")
        #expect(PointInTime.ParseError.future("2026-11-11").description == "2026-11-11 is in the future")
    }
}
