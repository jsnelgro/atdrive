import Foundation
import Testing

@testable import ATDriveCore

/// The change feed against a real spaces-enabled PDS. Skipped unless both are set:
///
///     ATDRIVE_LIVE_HANDLE=you.example.com ATDRIVE_LIVE_PASSWORD=xxxx-xxxx-xxxx-xxxx \
///         scripts/test.sh --filter LiveChangeFeedTests
///
/// Everything happens inside a uniquely named folder that is deleted at the end.
@Suite(.enabled(if: liveChangeFeedCredentials() != nil, "set ATDRIVE_LIVE_HANDLE and ATDRIVE_LIVE_PASSWORD"))
struct LiveChangeFeedTests {
    @Test func followsTheDriveWithoutListingItAgain() async throws {
        let (handle, password) = try #require(liveChangeFeedCredentials())
        let session = try await Auth.login(identifier: handle, password: password, resolver: IdentityResolver())
        let manager = SessionManager(session)
        let drive = try await openLiveDrive(session: session, manager: manager)

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
            await Auth.logout(await manager.session)
            throw error
        }
        try await drive.delete(created)
        snapshot = try await drive.update(snapshot)
        #expect(snapshot.tree.nodes[folder.id] == nil)
        #expect(snapshot.listedAt == listedAt)
        await Auth.logout(await manager.session)
    }
}

private func liveChangeFeedCredentials() -> (handle: String, password: String)? {
    let env = ProcessInfo.processInfo.environment
    guard let handle = env["ATDRIVE_LIVE_HANDLE"], let password = env["ATDRIVE_LIVE_PASSWORD"],
        !handle.isEmpty, !password.isEmpty
    else { return nil }
    return (handle, password)
}
