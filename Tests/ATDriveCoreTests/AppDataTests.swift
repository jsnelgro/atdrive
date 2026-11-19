import Foundation
import Testing

@testable import ATDriveCore

/// The apps view (#28): other apps' spaces, read-only. The account (`did:plc:test`, with its home
/// drive) owns a board that Bob writes on too, and Carol owns one she shares with it.
@Suite struct AppDataTests {
    let pds = FakePDS()
    let home: Drive
    let apps: AppData
    let me = FakePDS.defaultDID
    let bob: String
    let carol: String
    let board: String

    static let boardType = "my.bulletin.board"

    init() async throws {
        bob = pds.addAccount("bob")
        carol = pds.addAccount("carol")
        home = pds.device("here")
        _ = try await home.create(encrypted: TestMode.encrypted)
        apps = AppData(home: home, access: pds.access())
        board = try await pds.client().createSpace(
            type: Self.boardType, key: "home", policy: .members(publicRead: false))
        try await pds.client().putMembers(board, [SpaceMember(did: bob, read: true, write: true)])
    }

    func put(
        _ value: [String: Any], collection: String, rkey: String, in space: String, as did: String? = nil
    ) async throws {
        let did = did ?? me
        let record = try JSONValue(parsing: JSONSerialization.data(withJSONObject: value))
        try await pds.client(as: did).putSpaceRecord(
            space: space, repo: did, collection: collection, rkey: rkey, record: record)
    }

    func text(_ tree: AppTree, _ path: String) throws -> String? {
        guard let item = try tree.locate(DrivePath(path)), case .record(let data) = item.content else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func showsEveryCollectionAndWriterInASpace() async throws {
        try await put(
            ["$type": "my.bulletin.note", "text": "mine"], collection: "my.bulletin.note", rkey: "n1", in: board)
        try await put(["$type": "my.bulletin.pin", "x": 1], collection: "my.bulletin.pin", rkey: "p1", in: board)
        try await put(
            ["$type": "my.bulletin.note", "text": "bob's"], collection: "my.bulletin.note", rkey: "n2", in: board,
            as: bob)

        let snapshot = try await apps.update()
        let space = try #require(snapshot.spaces[board])
        #expect(Set(space.repos.keys) == [me, bob])
        #expect(space.problem == nil)
        let tree = snapshot.tree
        let folder = "test.test/\(Self.boardType) – home"
        #expect(try text(tree, "\(folder)/test.test/my.bulletin.note/n1.json")?.contains("\"text\": \"mine\"") == true)
        #expect(try tree.locate(DrivePath("\(folder)/test.test/my.bulletin.pin/p1.json")) != nil)
        #expect(try text(tree, "\(folder)/bob.test/my.bulletin.note/n2.json")?.contains("bob's") == true)
        #expect(tree.children(of: try tree.locate(DrivePath(folder))?.id).map(\.name) == ["bob.test", "test.test"])
    }

    @Test func leavesOutTheDrivesOwnSpaces() async throws {
        let folder = try await home.createFolder(named: "docs", in: nil)
        #expect(folder.name == "docs")
        let snapshot = try await apps.update()
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
            ], collection: "my.bulletin.note", rkey: "n1", in: board, as: bob)

        let snapshot = try await apps.update()
        let tree = snapshot.tree
        let base = "test.test/\(Self.boardType) – home/bob.test/my.bulletin.note"
        let json = try #require(try text(tree, "\(base)/n1.json"))
        #expect(json.contains("\"$type\": \"com.example.unknown.thing\""))
        #expect(json.contains("\"$bytes\": \"AAEC\""))
        #expect(json.contains("\"$link\": \"bafyreiexample\""))
        let file = try #require(try tree.locate(DrivePath("\(base)/n1.blobs/\(blob.cid).png")))
        #expect(file.size == image.count)
        let downloaded = try await apps.contents(of: file)
        #expect(downloaded == image)
    }

    @Test func readsAgainOnlyWhatMoved() async throws {
        try await put(["text": "a"], collection: "my.bulletin.note", rkey: "n1", in: board)
        try await put(["text": "b"], collection: "my.bulletin.note", rkey: "n2", in: board, as: bob)
        let first = try await apps.update()

        pds.resetCounts()
        let same = try await apps.update(first)
        #expect(same == first)
        // Just the spaces added by address, from the home drive.
        #expect(pds.count("com.atproto.space.listRecords") == 1)
        #expect(pds.count("com.atproto.space.listRepoOps") == 0)

        try await put(["text": "b2"], collection: "my.bulletin.note", rkey: "n2", in: board, as: bob)
        try await put(["text": "c"], collection: "my.bulletin.note", rkey: "n3", in: board, as: bob)
        pds.resetCounts()
        let moved = try await apps.update(first)
        // Bob's repo followed its change feed; nothing else was read again.
        #expect(pds.count("com.atproto.space.listRecords") == 1)
        #expect(pds.count("com.atproto.space.listRepoOps") >= 1)
        let bobs = try #require(moved.spaces[board]?.repos[bob])
        #expect(bobs.records["my.bulletin.note/n2"]?.value["text"]?.string == "b2")
        #expect(bobs.records["my.bulletin.note/n3"]?.value["text"]?.string == "c")
        #expect(moved.spaces[board]?.repos[me] == first.spaces[board]?.repos[me])
        #expect(moved.tree.anchor != first.tree.anchor)

        // The same as listing it afresh.
        let fresh = try await AppData(home: home, access: pds.access()).update()
        #expect(fresh.spaces == moved.spaces)
    }

    @Test func aSpaceThatRefusesATDriveIsShownWithWhy() async throws {
        try await put(["text": "mine"], collection: "my.bulletin.note", rkey: "n1", in: board)
        try await put(["text": "bob's"], collection: "my.bulletin.note", rkey: "n2", in: board, as: bob)
        pds.refusingApps = [board]

        let snapshot = try await apps.update()
        let space = try #require(snapshot.spaces[board])
        #expect(space.problem == .access(.appNotAllowed))
        #expect(Set(space.repos.keys) == [me])
        let tree = snapshot.tree
        let note = try #require(try tree.locate(DrivePath("test.test/\(Self.boardType) – home/UNREADABLE.txt")))
        let explanation = String(decoding: try await apps.contents(of: note), as: UTF8.self)
        #expect(explanation.contains("only certain apps"))
        #expect(explanation.contains("Only your own records"))
    }

    @Test func spacesSharedWithYouAreAddedByAddress() async throws {
        let carols = try await pds.client(as: carol).createSpace(
            type: Self.boardType, key: "kitchen", policy: .members(publicRead: false))
        try await pds.client(as: carol).putMembers(carols, [SpaceMember(did: me)])
        try await put(["text": "milk"], collection: "my.bulletin.note", rkey: "n1", in: carols, as: carol)

        // Never written to, so the PDS doesn't list it.
        #expect(try await apps.update().spaces[carols] == nil)

        let added = try await apps.add("at://carol.test/space/\(Self.boardType)/kitchen")
        #expect(added == carols)
        try await apps.add(carols)  // twice is fine
        #expect(try await apps.addedSpaces() == [carols])

        // Every device of the account sees it: it's in the home drive.
        let elsewhere = AppData(home: home, access: pds.access())
        let snapshot = try await elsewhere.update()
        let space = try #require(snapshot.spaces[carols])
        #expect(space.added)
        #expect(space.repos[carol]?.records["my.bulletin.note/n1"]?.value["text"]?.string == "milk")
        #expect(try snapshot.tree.locate(DrivePath("carol.test/\(Self.boardType) – kitchen/carol.test")) != nil)

        try await apps.remove(carols)
        #expect(try await apps.update().spaces[carols] == nil)
        await #expect(throws: AppDataError.notAdded(carols)) { try await apps.remove(carols) }
    }

    @Test func addingRefusesWhatIsntAnotherAppsSpace() async throws {
        await #expect(throws: AppDataError.notASpace("https://example.com")) {
            try await apps.add("https://example.com")
        }
        await #expect(throws: AppDataError.driveSpace) { try await apps.add(home.space) }
    }

    @Test func aRemovedMembersViewEmptiesOut() async throws {
        let carols = try await pds.client(as: carol).createSpace(
            type: Self.boardType, key: "kitchen", policy: .members(publicRead: false))
        try await pds.client(as: carol).putMembers(carols, [SpaceMember(did: me)])
        try await put(["text": "milk"], collection: "my.bulletin.note", rkey: "n1", in: carols, as: carol)
        try await apps.add(carols)
        let before = try await apps.update()
        #expect(before.spaces[carols]?.repos[carol] != nil)

        try await pds.client(as: carol).removeMembers(carols, dids: [me])
        let after = try await apps.update(before)
        let space = try #require(after.spaces[carols])
        #expect(space.repos.isEmpty)
        #expect(space.problem == .access(.notShared))
        let tree = after.tree
        let folder = try #require(try tree.locate(DrivePath("carol.test/\(Self.boardType) – kitchen")))
        #expect(tree.children(of: folder.id).map(\.name) == [AppTree.unreadableName])
        let changes = tree.changes(since: before.tree)
        #expect(changes.deleted.contains { $0.hasPrefix("r|") })
    }

    @Test func aGapInTheChangeFeedListsTheRepoAgain() async throws {
        try await put(["text": "a"], collection: "my.bulletin.note", rkey: "n1", in: board, as: bob)
        let first = try await apps.update()
        // Bob's repo moves on, and a record the snapshot has looks different from what the feed
        // says it was: it's listed again rather than patched.
        try await put(["text": "b"], collection: "my.bulletin.note", rkey: "n1", in: board, as: bob)
        var stale = first
        stale.spaces[board]?.repos[bob]?.records["my.bulletin.note/n1"]?.cid = "bafyelsewhere"
        pds.resetCounts()
        let updated = try await apps.update(stale)
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
