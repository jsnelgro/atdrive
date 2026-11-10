import Foundation
import Testing

@testable import ATDriveCore

/// The synced folder and history: which drive it's synced with, and races between devices.
extension FolderSyncTests {
    func savedState() throws -> SyncState {
        let data = try Data(contentsOf: folder.appendingPathComponent(".atdrive/state.json"))
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    @Test func aDriveWipedAndCreatedAgainStopsSync() async throws {
        try write("a.txt", "the only copy")
        let sync = try open()
        try await sync.sync()  // the first pass that finds the drive prunes it
        let id = try #require(try await drive.settings()?.driveID)
        #expect(try savedState().driveID == id && savedState().pruned != nil)

        // Wiped, and then another device made a new drive in the same place (with new keys).
        pds.wipe()
        _ = try await other.create()
        try await other.createFolder(named: "new", in: nil)
        #expect(try await drive.settings()?.driveID != id)
        await #expect(throws: SyncError.driveMissing(sync.root)) { try await sync.sync() }
        #expect(read("a.txt") == "the only copy")
        #expect(try await driveFiles() == ["new/"])  // and nothing from here went into it

        // Starting over (once this device has the new drive's keys) merges the folder into it.
        drive.use(try #require(other.keyring))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".atdrive"))
        let fresh = try open()
        try await fresh.sync()
        #expect(try await driveFiles() == ["a.txt", "new/"])
        #expect(try savedState().driveID == (try await drive.settings()?.driveID))
        try await expectSettled(fresh)
    }

    /// Creating a drive shows its recovery key, so only `atdrive login` does: never sync.
    @Test func syncNeverCreatesTheDrive() async throws {
        pds.wipe()
        let sync = try open()
        try await sync.sync()  // nothing to put in it yet
        try write("a.txt", "a")
        await #expect(throws: DriveAccessError.noDrive) { try await sync.sync() }
        #expect(!pds.spaceExists)
        #expect(read("a.txt") == "a")
    }

    @Test func aFirstSyncRemembersTheDrive() async throws {
        try write("a.txt", "a")
        let sync = try open()
        try await sync.sync()
        #expect(try savedState().driveID == (try await drive.settings()?.driveID))
        try await expectSettled(sync)
    }

    /// Another device, working from a stale view, writes over an edit this folder sent up:
    /// the next pass notices, and the edit comes back as a conflicted copy, here and there.
    @Test func anEditLostToAnotherDeviceComesBackAsACopy() async throws {
        try write("notes.txt", "v1")
        let log = Log()
        let sync = try FolderSync(folder: folder, drive: drive, settle: 0) { log.add($0) }
        try await sync.sync()
        let stale = try await node("/notes.txt")

        try write("notes.txt", "edited here")
        try await sync.sync()
        let scratch = try temporaryDirectory().appendingPathComponent("upload")
        try Data("edited elsewhere".utf8).write(to: scratch)
        try await other.upload(scratch, as: "notes.txt", in: nil, replacing: stale)

        try await sync.sync()
        let files = try localFiles()
        #expect(files.count == 2)
        #expect(read("notes.txt") == "edited elsewhere")
        let copy = try #require(files.first { $0.hasPrefix("notes (conflicted copy ") })
        #expect(read(copy) == "edited here")
        #expect(log.events.filter { $0.kind == .raced }.map(\.path) == ["/notes.txt"])
        try await expectSettled(sync)
    }

    @Test func aFileEditedHereButDeletedElsewhereMeanwhileComesBack() async throws {
        try write("docs/a.txt", "v1")
        let sync = try open()
        try await sync.sync()
        let stale = try await other.tree()

        try write("docs/a.txt", "edited here")
        try await sync.sync()
        // Another device deletes the folder, from before the edit.
        let docs = try #require(try stale.locate(DrivePath("/docs")))
        try await other.delete(stale.descendants(of: docs.id) + [docs])

        try await sync.sync()
        #expect(try localFiles() == ["docs/", "docs/a.txt"])
        #expect(read("docs/a.txt") == "edited here")
        #expect(try await driveContents("/docs/a.txt") == "edited here")
        try await expectSettled(sync)
    }
}
