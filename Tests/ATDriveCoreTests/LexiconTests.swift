import Foundation
import Testing

@testable import ATDriveCore

/// `lexicons/` matches the code: every file parses, the drive's space declaration lists the
/// collections the sign-in scope asks to write, and both scopes ask for what sharing needs.
@Suite struct LexiconTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("lexicons/me/jsnelgro/atdrive")

    @Test func lexiconsMatchTheCode() throws {
        var ids: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            let value = try JSONValue(parsing: Data(contentsOf: file))
            ids.insert(try #require(value["id"]?.string))
        }
        let records = [
            Lexicon.node, Lexicon.version, Lexicon.chunks, Lexicon.settings, Lexicon.device, Lexicon.member,
            Lexicon.link,
            Lexicon.contact, Lexicon.addedSpace,
        ]
        #expect(ids.isSuperset(of: records + [Lexicon.driveSpace, Lexicon.shareKey]))
        let drive = try JSONValue(parsing: Data(contentsOf: Self.directory.appendingPathComponent("drive.json")))
        let main = try #require(drive["defs"]?["main"])
        #expect(main["type"]?.string == "space")
        #expect(main["title"]?.string == "ATDrive")
        #expect(Set(main["collections"]?.array?.compactMap(\.string) ?? []) == Set(records))
    }

    @Test func scopesAskForWhatSharingNeeds() {
        for scope in [OAuthLogin.narrowScope, OAuthLogin.broadScope] {
            let parts = scope.split(separator: " ").map(String.init)
            #expect(parts.contains { $0.contains("manage=update") && $0.contains("manage=delete") })
            #expect(parts.contains { $0.hasSuffix("?authority=*&action=read") })
            #expect(parts.contains("repo:\(Lexicon.shareKey)"))
            for collection in [Lexicon.member, Lexicon.link, Lexicon.contact, Lexicon.addedSpace] {
                #expect(scope.contains("collection=\(collection)"))
            }
        }
        #expect(OAuthLogin.narrowScope.contains("space:\(Lexicon.driveSpace)?authority=*&action=read"))
        #expect(!OAuthLogin.narrowScope.contains("space:*"))
    }
}
