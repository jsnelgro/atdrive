import Foundation
import Testing

@testable import ATDriveCore

@Suite struct ConflictRulesTests {
    @Test func contents() {
        #expect(ConflictRules.contents(base: "a", local: "a", remote: "a") == .remote)  // nothing changed
        #expect(ConflictRules.contents(base: "a", local: "b", remote: "a") == .local)  // changed here
        #expect(ConflictRules.contents(base: "a", local: "a", remote: "c") == .remote)  // changed there
        #expect(ConflictRules.contents(base: "a", local: "b", remote: "b") == .remote)  // same change
        #expect(ConflictRules.contents(base: "a", local: "b", remote: "c") == .conflict)
        #expect(ConflictRules.contents(base: nil, local: "b", remote: "c") == .conflict)  // both new
    }

    @Test func locationTheDrivesMoveWins() {
        #expect(ConflictRules.location(base: "a", local: "a", remote: "a") == "a")
        #expect(ConflictRules.location(base: "a", local: "here", remote: "a") == "here")
        #expect(ConflictRules.location(base: "a", local: "a", remote: "there") == "there")
        #expect(ConflictRules.location(base: "a", local: "here", remote: "there") == "there")
    }

    @Test func deletesStandUnlessEditedElsewhere() {
        #expect(ConflictRules.deleteStands(base: "a", other: "a"))
        #expect(!ConflictRules.deleteStands(base: "a", other: "b"))
    }

    @Test func aDeletedFolderKeepsWhatChangedInside() {
        func node(_ id: String, _ name: String, in parent: String? = nil, folder: Bool = false, sha: String = "s")
            -> Node
        {
            Node(
                id: id, cid: "\(id)-\(name)-\(parent ?? "")-\(sha)",
                record: NodeRecord(name: name, parent: parent, kind: folder ? .folder : .file, sha256: sha))
        }
        let seen = DriveTree([
            node("p", "project", folder: true),
            node("old", "old.txt", in: "p"),
            node("edited", "edited.txt", in: "p"),
            node("renamed", "renamed.txt", in: "p"),
            node("sub", "sub", in: "p", folder: true),
            node("deep", "deep.txt", in: "sub"),
            node("outside", "outside.txt"),
        ])
        let now = DriveTree([
            node("p", "project", folder: true),
            node("old", "old.txt", in: "p"),
            node("edited", "edited.txt", in: "p", sha: "new contents"),
            node("renamed", "renamed later.txt", in: "p"),
            node("sub", "sub", in: "p", folder: true),
            node("deep", "deep.txt", in: "sub"),
            node("added", "added.txt", in: "sub"),
            node("outside", "outside.txt", in: "p"),  // moved in
        ])
        #expect(
            ConflictRules.keptWhenDeleting(folder: "p", now: now, seen: seen) == [
                "p", "edited", "sub", "added", "outside",
            ])
        #expect(ConflictRules.keptWhenDeleting(folder: "sub", now: seen, seen: seen).isEmpty)
    }
}

/// The synced folder and the Mac app's rule for deleted folders agree.
@Suite struct ConflictRulesAgreeWithSyncTests {
    @Test func folderDeletedHere() async throws {
        let sync = try FolderSyncTests()
        try sync.write("project/old.txt", "old")
        try sync.write("project/edited.txt", "v1")
        try sync.write("project/sub/deep.txt", "deep")
        try sync.write("outside.txt", "outside")
        let folder = try FolderSync(folder: sync.folder, drive: sync.drive, settle: 0)
        try await folder.sync()
        let seen = try await sync.other.tree()

        // Elsewhere: edit a file in the folder, add one, move one in. Here: delete the folder.
        try await sync.put("/project/edited.txt", "v2, edited elsewhere")
        try await sync.put("/project/sub/added.txt", "added elsewhere")
        try await sync.other.move(
            try await sync.node("/outside.txt"), to: try await sync.node("/project").id, as: "outside.txt")
        let now = try await sync.other.tree()
        let expected = ConflictRules.keptWhenDeleting(
            folder: try #require(try now.locate(DrivePath("/project"))).id, now: now, seen: seen)

        try sync.remove("project")
        try await folder.sync()
        let after = try await sync.other.tree()
        let keptBySync = Set(
            now.descendants(of: try #require(try now.locate(DrivePath("/project"))).id).map(\.id)
                .filter { after.nodes[$0] != nil })
        #expect(keptBySync.union([try #require(try after.locate(DrivePath("/project"))).id]) == expected)
        #expect(
            try sync.localFiles() == [
                "project/", "project/edited.txt", "project/outside.txt", "project/sub/", "project/sub/added.txt",
            ])
    }
}
