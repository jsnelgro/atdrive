import Foundation
import Testing

@testable import ATDriveCore

/// Sharing against a real spaces-enabled PDS, with two accounts signed in with `atdrive login`
/// into folders of their own (see `LiveTests`):
///
///     ATDRIVE_LIVE_STATE=~/.atdrive-live-a ATDRIVE_LIVE_STATE_B=~/.atdrive-live-b \
///         scripts/test.sh --filter LiveSharingTests
///
/// The first account shares a new folder with the second, by link and as a member; the second
/// reads it; then it's unshared and its space deleted. Each account's drive must exist.
@Suite(
    .enabled(
        if: LiveAccount.load() != nil && LiveAccount.load("ATDRIVE_LIVE_STATE_B") != nil,
        "set ATDRIVE_LIVE_STATE and ATDRIVE_LIVE_STATE_B to folders `atdrive login` saved to"))
struct LiveSharingTests {
    @Test func shareReadUnshare() async throws {
        let a = try #require(LiveAccount.load())
        let b = try #require(LiveAccount.load("ATDRIVE_LIVE_STATE_B"))
        let owner = JoinedDrive(
            home: try await a.openDrive(), access: SpaceAccess(ownClient: a.client, resolver: IdentityResolver()))
        let reader = JoinedDrive(
            home: try await b.openDrive(), access: SpaceAccess(ownClient: b.client, resolver: IdentityResolver()))
        try await owner.ensureSharingKey()
        try await reader.ensureSharingKey()

        let name = "atdrive-live-share-\(TID.next())"
        let folder = try await owner.createFolder(named: name, in: nil)
        let file = try temporaryDirectory().appendingPathComponent("hello.txt")
        try Data("shared over the live PDS".utf8).write(to: file)
        _ = try await owner.upload(file, as: "hello.txt", in: folder.id)
        var mount = try await owner.share(folder)
        let space = try #require(mount.record.mount?.space)

        // By link, signed out.
        let link = try await owner.turnLinkOn(mount)
        let opened = try await JoinedDrive.open(link, access: SpaceAccess(ownClient: nil, resolver: IdentityResolver()))
        #expect(opened.name == name)
        let tree = try await opened.drive.tree()
        #expect(try tree.locate(DrivePath("/hello.txt")) != nil)

        // As a member.
        try await owner.turnLinkOff(mount)
        try await owner.addMembers([b.session.did], to: mount, allowingChangedKeys: true)
        let added = try await reader.add(ShareLinkAddress(space: link.space))
        let theirs = try await reader.tree()
        let hello = try #require(try theirs.locate(DrivePath("/\(added.name)/hello.txt")))
        var data = Data()
        try await reader.read(hello) { data.append($0) }
        #expect(String(decoding: data, as: UTF8.self) == "shared over the live PDS")

        // Removed: held, not empty.
        try await owner.removeMembers([b.session.did], from: mount)
        let after = try await reader.update(nil)
        #expect(after.mounts[added.id]?.problem != nil)
        try await reader.delete([added])

        mount = try await owner.current(mount)
        try await owner.unshare(mount)
        let ownerTree = try await owner.tree()
        try await owner.delete(ownerTree.descendants(of: mount.id) + [mount])
        try await a.client.deleteSpace(space)
    }
}
