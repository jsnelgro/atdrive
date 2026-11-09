import Testing

@testable import ATDriveCore

@Suite struct DriveTreeTests {
    func node(_ id: String, _ name: String, parent: String? = nil, folder: Bool = false) -> Node {
        Node(
            id: id, cid: "cid-\(id)",
            record: NodeRecord(name: name, parent: parent, kind: folder ? .folder : .file, size: 1))
    }

    var sample: DriveTree {
        DriveTree([
            node("d1", "docs", folder: true),
            node("f1", "b.txt"),
            node("f2", "A.txt", parent: "d1"),
            node("d2", "nested", parent: "d1", folder: true),
            node("f3", "deep.txt", parent: "d2"),
            node("f0", "Zed.txt"),
            node("d0", "archive", folder: true),
        ])
    }

    @Test func findsByPath() throws {
        let tree = sample
        #expect(try tree.find(.root) == .root)
        #expect(try tree.locate(DrivePath("/docs/nested/deep.txt"))?.id == "f3")
        #expect(try tree.find(DrivePath("/docs/missing.txt")) == .missing)
        #expect(throws: ATDriveError.notAFolder("/b.txt")) { try tree.find(DrivePath("/b.txt/x")) }
        #expect(throws: ATDriveError.notFound("/nope")) { try tree.locate(DrivePath("/nope")) }
    }

    @Test func listsFoldersFirstThenByName() {
        #expect(sample.children(of: nil).map(\.name) == ["archive", "docs", "b.txt", "Zed.txt"])
    }

    @Test func pathsAndContainment() {
        let tree = sample
        #expect(tree.path(of: tree.nodes["f3"]!).description == "/docs/nested/deep.txt")
        #expect(tree.isInside("d2", folder: "d1"))
        #expect(!tree.isInside("d1", folder: "d2"))
        // Deepest first, so deleting in this order never orphans anything.
        #expect(tree.descendants(of: "d1").map(\.id).first == "f3")
        #expect(Set(tree.descendants(of: "d1").map(\.id)) == ["f2", "d2", "f3"])
    }

    @Test func orphansAndCyclesShowAtTheTop() {
        let tree = DriveTree([
            node("o1", "orphan.txt", parent: "deleted-folder"),
            node("x", "x", parent: "y", folder: true),
            node("y", "y", parent: "x", folder: true),
            node("f", "under-file.txt", parent: "o1"),  // parent is a file, not a folder
        ])
        let top = Set(tree.children(of: nil).map(\.id))
        #expect(top.isSuperset(of: ["o1", "f"]))
        // One of the two folders in the cycle is lifted to the top; the other stays inside it.
        #expect(top.contains("x") != top.contains("y"))
        #expect(tree.nodes.count == 4)
        for node in tree.nodes.values { _ = tree.path(of: node) }  // terminates
    }
}

@Suite struct DriveTreeChangeTests {
    func node(_ id: String, _ name: String, parent: String? = nil, folder: Bool = false, cid: String? = nil) -> Node {
        Node(
            id: id, cid: cid ?? "cid-\(id)",
            record: NodeRecord(name: name, parent: parent, kind: folder ? .folder : .file, size: 1))
    }

    @Test func reportsNewEditedMovedAndDeleted() {
        let before = DriveTree([
            node("d1", "docs", folder: true),
            node("f1", "a.txt", parent: "d1"),
            node("f2", "b.txt"),
            node("f3", "c.txt"),
        ])
        let after = DriveTree([
            node("d1", "docs", folder: true),
            node("f1", "a.txt", parent: "d1", cid: "edited"),  // edited
            node("f2", "b.txt", parent: "d1", cid: "moved"),  // moved into docs
            node("f4", "new.txt"),  // new
        ])  // f3 deleted
        let changes = after.changes(since: before)
        #expect(changes.updated.map(\.id) == ["f1", "f2", "f4"])
        #expect(changes.deleted == ["f3"])
        #expect(after.changes(since: after).updated.isEmpty)
    }

    func unreadable(_ id: String) -> UnreadableNode {
        UnreadableNode(id: id, cid: "cid-\(id)-new", reason: .newerFormat, value: nil)
    }

    @Test func unreadableRecordsAreNotDeletionsAndKeepWhatsInside() {
        let before = DriveTree([
            node("d1", "docs", folder: true),
            node("f1", "a.txt", parent: "d1"),
            node("d2", "sub", parent: "d1", folder: true),
            node("f2", "deep.txt", parent: "d2"),
            node("f3", "top.txt"),
        ])
        // docs can't be read any more (say, a newer format), and something inside it changed.
        let after = DriveTree(
            [
                node("f1", "a.txt", parent: "d1", cid: "edited"),
                node("d2", "sub", parent: "d1", folder: true),
                node("f2", "deep.txt", parent: "d2"),
                node("f3", "top.txt"),
            ], unreadable: [unreadable("d1")])
        #expect(after.children(of: nil).map(\.id) == ["f3"])  // not lifted to the top
        #expect(after.unreadableContainer(of: "f2") == "d1")
        #expect(after.unreadableContainer(of: "f3") == nil)
        #expect(after.children(of: "d1").map(\.id) == ["d2", "f1"])
        let changes = after.changes(since: before)
        #expect(changes.deleted.isEmpty)
        #expect(changes.updated.isEmpty)  // left as last seen until it can be read

        // Readable again: everything inside it is reported, wherever it is now.
        let readable = DriveTree([node("d1", "docs", folder: true)] + after.nodes.values)
        #expect(readable.changes(since: after).updated.map(\.id) == ["d1", "d2", "f1", "f2"])
        // Gone for good: reported as deleted.
        let gone = DriveTree(Array(after.nodes.values.filter { $0.id == "f3" }))
        #expect(gone.changes(since: after).deleted == ["d1", "d2", "f1", "f2"])
    }

    @Test func reportsChildrenLiftedToTheTopWhenTheirFolderGoes() {
        let before = DriveTree([node("d1", "docs", folder: true), node("f1", "a.txt", parent: "d1")])
        let after = DriveTree([node("f1", "a.txt", parent: "d1")])  // record unchanged, folder gone
        #expect(after.parent(of: "f1") == nil)
        let changes = after.changes(since: before)
        #expect(changes.updated.map(\.id) == ["f1"])
        #expect(changes.deleted == ["d1"])
    }
}
