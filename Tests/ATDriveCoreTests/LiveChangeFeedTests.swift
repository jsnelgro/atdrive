import Foundation
import Testing

@testable import ATDriveCore

/// The change feed against a real spaces-enabled PDS. Skipped unless `ATDRIVE_LIVE_CONFIG` is
/// set (see `LiveTests`). Everything happens inside a uniquely named folder that is deleted at the
/// end.
@Suite(.enabled(if: LiveAccount.load() != nil, "set ATDRIVE_LIVE_CONFIG to a folder `atdrive login` saved to"))
struct LiveChangeFeedTests {
    @Test func followsTheDriveWithoutListingItAgain() async throws {
        let account = try #require(LiveAccount.load())
        let drive = try await account.openDrive()

        // A full listing: every collection, and the commit it's at.
        var snapshot = try await drive.update(nil)
        let listedAt = snapshot.listedAt
        let folder = try await drive.createFolder(named: "atdrive-live-feed-\(TID.next())", in: nil)
        var created = [folder]
        do {
            let file = try temporaryDirectory().appendingPathComponent("x.txt")
            try Data("change feed".utf8).write(to: file)
            let uploaded = try await drive.upload(file, as: "x.txt", in: folder.id)
            created.insert(uploaded, at: 0)
            let renamed = try await drive.move(uploaded, to: folder.id, as: "renamed.txt")

            snapshot = try await drive.update(snapshot)
            #expect(snapshot.listedAt == listedAt, "followed the feed, without a full listing")
            #expect(snapshot.tree.nodes[renamed.id]?.name == "renamed.txt")
            #expect(snapshot.tree.nodes[renamed.id]?.cid == renamed.cid)
            #expect(snapshot.repo.cid(Lexicon.node, folder.id) == folder.cid)
            #expect(snapshot.repo.data?.count == 32)

            let fresh = try await drive.listEverything()
            #expect(fresh.revision == snapshot.revision)
            #expect(fresh.repo.records == snapshot.repo.records)
            #expect(fresh.tree.nodes == snapshot.tree.nodes)
        } catch {
            try? await drive.delete(created)
            throw error
        }
        try await drive.delete(created)
        snapshot = try await drive.update(snapshot)
        #expect(snapshot.tree.nodes[folder.id] == nil)
        #expect(snapshot.listedAt == listedAt)
    }
}
