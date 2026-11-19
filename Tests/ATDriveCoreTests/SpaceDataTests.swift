import Foundation
import Testing

@testable import ATDriveCore

/// The spaces view (#28): every space the account is in, read-only. The account (`did:plc:test`,
/// with its home drive) owns a board Bob writes on too, and Carol owns one she shares with it.
@Suite struct SpaceDataTests {
    let pds = FakePDS()
    let home: Drive
    let spaces: SpaceData
    let me = FakePDS.defaultDID
    let bob: String
    let carol: String
    let board: String

    static let boardType = "my.bulletin.board"
    /// The board type's folder, with no title declared: its domain.
    static let app = "bulletin.my"

    init() async throws {
        bob = pds.addAccount("bob")
        carol = pds.addAccount("carol")
        home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        spaces = SpaceData(home: home, access: pds.access())
        board = try await pds.client().createSpace(
            type: Self.boardType, key: "home", policy: .members(publicRead: false))
        try await pds.client().putMembers(board, [SpaceMember(did: bob, read: true, write: true)])
    }

    func put(
        _ value: [String: Any], collection: String = "my.bulletin.note", rkey: String, in space: String,
        as did: String? = nil
    ) async throws {
        let did = did ?? me
        let record = try JSONValue(parsing: JSONSerialization.data(withJSONObject: value))
        try await pds.client(as: did).putSpaceRecord(
            space: space, repo: did, collection: collection, rkey: rkey, record: record)
    }

    func text(_ tree: SpaceTree, _ path: String) throws -> String? {
        guard let item = try tree.locate(DrivePath(path)), case .record(let data) = item.content else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func names(_ tree: SpaceTree, in path: String) throws -> [String] {
        tree.children(of: try tree.locate(DrivePath(path))?.id).map(\.name)
    }

    /// Carol's board, shared with the account, which never wrote to it.
    func carolsKitchen() async throws -> String {
        let kitchen = try await pds.client(as: carol).createSpace(
            type: Self.boardType, key: "kitchen", policy: .members(publicRead: false))
        try await pds.client(as: carol).putMembers(kitchen, [SpaceMember(did: me)])
        try await put(["text": "milk"], rkey: "n1", in: kitchen, as: carol)
        return kitchen
    }

    @Test func laysOutByAppThenSpaceThenRecordType() async throws {
        try await put(["$type": "my.bulletin.note", "text": "mine"], rkey: "n1", in: board)
        try await put(["$type": "my.bulletin.pin", "x": 1], collection: "my.bulletin.pin", rkey: "p1", in: board)
        try await put(["$type": "my.bulletin.note", "text": "bob's"], rkey: "n2", in: board, as: bob)
        try await put(["like": true], collection: "org.example.reaction", rkey: "r1", in: board, as: bob)

        let snapshot = try await spaces.update()
        let space = try #require(snapshot.spaces[board])
        #expect(Set(space.repos.keys) == [me, bob])
        #expect(space.problem == nil)
        let tree = snapshot.tree
        #expect(try names(tree, in: "/") == [Self.app])
        #expect(try names(tree, in: Self.app) == ["home"])
        // Record types without the board's domain, unless they're from another one.
        #expect(try names(tree, in: "\(Self.app)/home") == ["note", "org.example.reaction", "pin"])
        // Everyone's records together, other people's starting with their handle.
        #expect(try names(tree, in: "\(Self.app)/home/note") == ["@bob.test n2.json", "n1.json"])
        #expect(try text(tree, "\(Self.app)/home/note/n1.json")?.contains("\"text\": \"mine\"") == true)
        #expect(try text(tree, "\(Self.app)/home/note/@bob.test n2.json")?.contains("bob's") == true)
        #expect(try tree.locate(DrivePath("\(Self.app)/home/pin/p1.json")) != nil)
        #expect(try tree.locate(DrivePath("\(Self.app)/home/org.example.reaction/@bob.test r1.json")) != nil)
    }

    @Test func appsAreNamedByTheirSpaceTypesTitle() async throws {
        pds.lexicons[Self.boardType] = [
            "lexicon": 1, "id": Self.boardType,
            "defs": ["main": ["type": "space", "key": "any", "title": "Bulletin", "collections": []]],
        ]
        try await put(["text": "a"], rkey: "n1", in: board)
        let tree = try await spaces.update().tree
        #expect(try names(tree, in: "/") == ["Bulletin"])
        #expect(try tree.locate(DrivePath("Bulletin/home/note/n1.json")) != nil)
    }

    @Test func typesThatWouldShareANameAreToldApart() {
        let names = SpaceTree.appNames(
            ["my.bulletin.board", "my.bulletin.chat", "com.atmoboards.forum"], titles: ["com.atmoboards.forum": "Forum"]
        )
        #expect(names["my.bulletin.board"] == "bulletin.my (board)")
        #expect(names["my.bulletin.chat"] == "bulletin.my (chat)")
        #expect(names["com.atmoboards.forum"] == "Forum")
    }

    @Test func leavesOutTheDrivesOwnSpaces() async throws {
        _ = try await home.createFolder(named: "docs", in: nil)
        let snapshot = try await spaces.update()
        #expect(snapshot.spaces.keys.allSatisfy { XRPCClient.spaceParts($0)?.type != Lexicon.driveSpace })
        #expect(snapshot.spaces[home.space] == nil)
    }

    @Test func recordsAreShownAsStoredWithTheirBlobs() async throws {
        let image = Data("a picture".utf8)
        let blob = try await pds.client(as: bob).uploadBlob(image, mimeType: "image/png")
        // As the app that wrote it says: a PNG.
        let blobJSON: [String: Any] = [
            "$type": "blob", "ref": ["$link": blob.cid], "mimeType": "image/png", "size": image.count,
        ]
        try await put(
            [
                "$type": "com.example.unknown.thing", "photo": blobJSON,
                "raw": ["$bytes": "AAEC"], "ref": ["$link": "bafyreiexample"],
            ], rkey: "n1", in: board, as: bob)

        let tree = try await spaces.update().tree
        let note = "\(Self.app)/home/note"
        #expect(try names(tree, in: note) == ["@bob.test n1.blobs", "@bob.test n1.json"])
        let json = try #require(try text(tree, "\(note)/@bob.test n1.json"))
        #expect(json.contains("\"$type\": \"com.example.unknown.thing\""))
        #expect(json.contains("\"$bytes\": \"AAEC\""))
        #expect(json.contains("\"$link\": \"bafyreiexample\""))
        let file = try #require(try tree.locate(DrivePath("\(note)/@bob.test n1.blobs/\(blob.cid).png")))
        #expect(file.size == image.count)
        let downloaded = try await spaces.contents(of: file)
        #expect(downloaded == image)
    }

    @Test func readsAgainOnlyWhatMoved() async throws {
        try await put(["text": "a"], rkey: "n1", in: board)
        try await put(["text": "b"], rkey: "n2", in: board, as: bob)
        let first = try await spaces.update()

        pds.resetCounts()
        let same = try await spaces.update(first)
        #expect(same == first)
        // Just the spaces added by address, from the home drive.
        #expect(pds.count("com.atproto.space.listRecords") == 1)
        #expect(pds.count("com.atproto.space.listRepoOps") == 0)

        try await put(["text": "b2"], rkey: "n2", in: board, as: bob)
        try await put(["text": "c"], rkey: "n3", in: board, as: bob)
        pds.resetCounts()
        let moved = try await spaces.update(first)
        // Bob's repo followed its change feed; nothing else was read again.
        #expect(pds.count("com.atproto.space.listRecords") == 1)
        #expect(pds.count("com.atproto.space.listRepoOps") >= 1)
        let bobs = try #require(moved.spaces[board]?.repos[bob])
        #expect(bobs.records["my.bulletin.note/n2"]?.value["text"]?.string == "b2")
        #expect(bobs.records["my.bulletin.note/n3"]?.value["text"]?.string == "c")
        #expect(moved.spaces[board]?.repos[me] == first.spaces[board]?.repos[me])
        #expect(moved.tree.anchor != first.tree.anchor)

        // The same as listing it afresh.
        let fresh = try await SpaceData(home: home, access: pds.access()).update()
        #expect(fresh.spaces == moved.spaces)
    }

    @Test func aSpaceThatRefusesATDriveIsMarkedWithWhy() async throws {
        try await put(["text": "mine"], rkey: "n1", in: board)
        try await put(["text": "bob's"], rkey: "n2", in: board, as: bob)
        pds.refusingApps = [board]

        let snapshot = try await spaces.update()
        let space = try #require(snapshot.spaces[board])
        #expect(space.problem == .access(.appNotAllowed))
        #expect(Set(space.repos.keys) == [me])
        let tree = snapshot.tree
        let folder = try #require(try tree.locate(DrivePath("\(Self.app)/home")))
        #expect(folder.unreadable?.contains("only certain apps") == true)
        // Your own records are still there.
        #expect(try names(tree, in: "\(Self.app)/home/note") == ["n1.json"])
    }

    @Test func spacesSharedWithYouAreAddedByAddress() async throws {
        let kitchen = try await carolsKitchen()

        // Never written to, so the PDS doesn't list it.
        #expect(try await spaces.update().spaces[kitchen] == nil)

        let added = try await spaces.add("at://carol.test/space/\(Self.boardType)/kitchen")
        #expect(added == kitchen)
        try await spaces.add(kitchen)  // twice is fine
        #expect(try await spaces.addedSpaces() == [kitchen])

        // Every device of the account sees it: it's in the home drive.
        let elsewhere = SpaceData(home: home, access: pds.access())
        let snapshot = try await elsewhere.update()
        let space = try #require(snapshot.spaces[kitchen])
        #expect(space.added)
        #expect(space.repos[carol]?.records["my.bulletin.note/n1"]?.value["text"]?.string == "milk")
        // Someone else's space starts with its owner's handle.
        #expect(try names(snapshot.tree, in: "\(Self.app)/@carol.test kitchen/note") == ["@carol.test n1.json"])

        try await spaces.remove(kitchen)
        #expect(try await spaces.update().spaces[kitchen] == nil)
        await #expect(throws: SpaceDataError.notAdded(kitchen)) { try await spaces.remove(kitchen) }
    }

    @Test func addingRefusesWhatIsntAnotherAppsSpace() async throws {
        await #expect(throws: SpaceDataError.notASpace("https://example.com")) {
            try await spaces.add("https://example.com")
        }
        await #expect(throws: SpaceDataError.driveSpace) { try await spaces.add(home.space) }
    }

    @Test func aRemovedMembersViewEmptiesOut() async throws {
        let kitchen = try await carolsKitchen()
        try await spaces.add(kitchen)
        let before = try await spaces.update()
        #expect(before.spaces[kitchen]?.repos[carol] != nil)

        try await pds.client(as: carol).removeMembers(kitchen, dids: [me])
        let after = try await spaces.update(before)
        let space = try #require(after.spaces[kitchen])
        #expect(space.repos.isEmpty)
        #expect(space.problem == .access(.notShared))
        let tree = after.tree
        let folder = try #require(try tree.locate(DrivePath("\(Self.app)/@carol.test kitchen")))
        #expect(folder.unreadable != nil)
        #expect(tree.children(of: folder.id).isEmpty)
        let changes = tree.changes(since: before.tree)
        #expect(changes.deleted.contains { $0.hasPrefix("r|") })
        #expect(changes.updated.contains { $0.id == folder.id })
    }

    @Test func aGapInTheChangeFeedListsTheRepoAgain() async throws {
        try await put(["text": "a"], rkey: "n1", in: board, as: bob)
        let first = try await spaces.update()
        // Bob's repo moves on, and a record the snapshot has looks different from what the feed
        // says it was: it's listed again rather than patched.
        try await put(["text": "b"], rkey: "n1", in: board, as: bob)
        var stale = first
        stale.spaces[board]?.repos[bob]?.records["my.bulletin.note/n1"]?.cid = "bafyelsewhere"
        pds.resetCounts()
        let updated = try await spaces.update(stale)
        #expect(pds.count("com.atproto.space.listRecords") >= 1)
        #expect(updated.spaces[board]?.repos[bob]?.records["my.bulletin.note/n1"]?.value["text"]?.string == "b")
    }

    @Test func prettyJSON() throws {
        let value = try JSONValue(parsing: Data(#"{"b":[1,{"c":null}],"a":{},"d":[]}"#.utf8))
        let expected = """
            {
              "a": {},
              "b": [
                1,
                {
                  "c": null
                }
              ],
              "d": []
            }

            """
        #expect(String(decoding: value.prettySerialized(), as: UTF8.self) == expected)
    }

    @Test func addedSpaceKeysAreValidRecordKeys() {
        let key = AddedSpace.key(for: "at://did:plc:abc/space/my.bulletin.board/home")
        #expect(key.count == 26)
        #expect(key.allSatisfy { $0.isLowercase || $0.isNumber })
        #expect(AddedSpace.key(for: "at://did:plc:abc/space/my.bulletin.board/home") == key)
    }
}
