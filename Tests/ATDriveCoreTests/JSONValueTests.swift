import Foundation
import Testing

@testable import ATDriveCore

@Suite struct JSONValueTests {
    @Test func parsesEveryKindOfValue() throws {
        let text = #"""
            { "s": "plain", "e": "q\" b\\ s\/ \b\f\n\r\t u\u00e9 \ud83d\ude00 lone\ud800!", "i": -42, "big": 9007199254740993,
              "d": 1.5, "x": 2e3, "t": true, "f": false, "n": null, "a": [1, "two", [], {}], "o": {"k": {"$link": "b"}} }
            """#
        let value = try JSONValue(parsing: Data(text.utf8))
        #expect(value["s"] == .string("plain"))
        #expect(value["e"] == .string("q\" b\\ s/ \u{8}\u{c}\n\r\t u\u{e9} \u{1F600} lone\u{FFFD}!"))
        #expect(value["i"] == .integer(-42))
        #expect(value["big"] == .integer(9_007_199_254_740_993))  // exact, beyond a Double's precision
        #expect(value["d"] == .number(1.5))
        #expect(value["x"] == .number(2000))
        #expect(value["t"] == .bool(true) && value["f"] == .bool(false))
        #expect(value["n"] == .null)
        #expect(value["a"] == .array([.integer(1), .string("two"), .array([]), .object([:])]))
        #expect(value["o"]?["k"]?["$link"]?.string == "b")
    }

    @Test func writesWhatItReads() throws {
        let value = JSONValue.object([
            "name": .string("a \"quoted\"\nname\u{1}é"), "n": .integer(-3), "f": .number(0.25), "yes": .bool(true),
            "list": .array([.null, .object(["k": .string("v")])]),
        ])
        #expect(try JSONValue(parsing: value.serialized()) == value)
        // Foundation reads it the same way.
        let foundation = try JSONSerialization.jsonObject(with: value.serialized()) as? [String: Any]
        #expect(foundation?["name"] as? String == "a \"quoted\"\nname\u{1}é")
        // And it's interchangeable with Codable.
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func decodesRecords() throws {
        let record = NodeRecord(name: "a.txt", parent: "p", kind: .file, size: 3, sha256: "abc", chunks: [])
        let value = try JSONValue(encoding: record)
        #expect(value["$type"]?.string == Lexicon.node)
        #expect(try value.decode(as: NodeRecord.self) == record)
    }

    @Test func rejectsWhatIsntJSON() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"open", "1 2", "{\"a\":1,}", "-", "\"\\x\""] {
            #expect(throws: JSONValue.SyntaxError.self, "\(text)") { try JSONValue(parsing: Data(text.utf8)) }
        }
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: JSONValue.SyntaxError.self) { try JSONValue(parsing: Data(deep.utf8)) }
    }
}
