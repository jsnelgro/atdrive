import Foundation
import Testing

@testable import ATDriveCore

/// End-to-end against a real spaces-enabled PDS. Skipped unless both are set:
///
///     ATDRIVE_LIVE_HANDLE=you.example.com ATDRIVE_LIVE_PASSWORD=xxxx-xxxx-xxxx-xxxx \
///         scripts/test.sh --filter LiveTests
///
/// Everything happens inside a uniquely named folder that is deleted at the end.
@Suite(.enabled(if: liveCredentials() != nil, "set ATDRIVE_LIVE_HANDLE and ATDRIVE_LIVE_PASSWORD"))
struct LiveTests {
    @Test func roundTrip() async throws {
        let (handle, password) = try #require(liveCredentials())
        let session = try await Auth.login(identifier: handle, password: password, resolver: IdentityResolver())
        let manager = SessionManager(session)
        // Small chunks so a modest file still spans several blobs.
        let drive = Drive(
            client: XRPCClient(service: session.service, session: manager), owner: session.did,
            chunkSize: 64 * 1024)

        let folderName = "atdrive-live-test-\(TID.next())"
        let folder = try await drive.createFolder(named: folderName, in: nil)
        var created = [folder]
        do {
            let directory = try temporaryDirectory()
            let source = directory.appendingPathComponent("random.bin")
            var bytes = [UInt8](repeating: 0, count: 200_000)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            try Data(bytes).write(to: source)

            let file = try await drive.upload(source, as: "random.bin", in: folder.id)
            created.insert(file, at: 0)
            #expect(file.record.chunks?.count == 4)

            let tree = try await drive.tree()
            let listed = try #require(try tree.locate(DrivePath("/\(folderName)/random.bin")))
            #expect(listed.id == file.id)

            let copy = directory.appendingPathComponent("copy.bin")
            try await drive.download(listed, to: copy)
            #expect(try Data(contentsOf: copy) == Data(bytes))

            let renamed = try await drive.move(listed, to: folder.id, as: "renamed.bin")
            #expect(try await drive.tree().locate(DrivePath("/\(folderName)/renamed.bin"))?.id == renamed.id)
        } catch {
            try? await drive.delete(created)
            await Auth.logout(await manager.session)
            throw error
        }
        try await drive.delete(created)
        #expect(try await drive.tree().child(named: folderName, in: nil) == nil)
        await Auth.logout(await manager.session)
    }
}

private func liveCredentials() -> (handle: String, password: String)? {
    let env = ProcessInfo.processInfo.environment
    guard let handle = env["ATDRIVE_LIVE_HANDLE"], let password = env["ATDRIVE_LIVE_PASSWORD"],
        !handle.isEmpty, !password.isEmpty
    else { return nil }
    return (handle, password)
}
