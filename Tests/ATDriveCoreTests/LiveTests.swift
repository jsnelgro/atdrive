import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// End-to-end against a real spaces-enabled PDS, as an account signed in with `atdrive login`
/// into a folder of its own (spaces take OAuth only, so tests reuse a saved session):
///
///     ATDRIVE_CONFIG_DIR=~/.atdrive-live-a atdrive login you.example.com
///     ATDRIVE_LIVE_CONFIG=~/.atdrive-live-a scripts/test.sh --filter Live
///
/// Everything happens inside a uniquely named folder that is deleted at the end.
@Suite(.enabled(if: LiveAccount.load() != nil, "set ATDRIVE_LIVE_CONFIG to a folder `atdrive login` saved to"))
struct LiveTests {
    @Test func roundTrip() async throws {
        let account = try #require(LiveAccount.load())
        // Small chunks so a modest file still spans several blobs.
        let drive = try await account.openDrive(
            transfers: TransferOptions(chunking: .init(minSize: 16 << 10, averageSize: 64 << 10, maxSize: 128 << 10)))

        let folderName = "atdrive-live-test-\(TID.next())"
        let revisionBefore = try await drive.latestRevision()
        let folder = try await drive.createFolder(named: folderName, in: nil)
        let revisionAfter = try await drive.latestRevision()
        #expect(revisionAfter != nil && revisionAfter != revisionBefore)
        var created = [folder]
        do {
            let directory = try temporaryDirectory()
            let source = directory.appendingPathComponent("random.bin")
            var bytes = [UInt8](repeating: 0, count: 200_000)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            try Data(bytes).write(to: source)

            let file = try await drive.upload(source, as: "random.bin", in: folder.id)
            created.insert(file, at: 0)
            #expect((file.record.chunks?.count ?? 0) > 1)

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
            throw error
        }
        try await drive.delete(created)
        #expect(try await drive.tree().child(named: folderName, in: nil) == nil)
    }
}

/// An account signed in with `atdrive login` into a folder of its own, for live tests: the folder
/// named by `variable` (`ATDRIVE_LIVE_CONFIG`; `ATDRIVE_LIVE_CONFIG_B` is a second account, for
/// sharing). Token refreshes are saved back there.
struct LiveAccount: Sendable {
    let store: SessionStore
    let session: Session
    let manager: SessionManager

    static func load(_ variable: String = "ATDRIVE_LIVE_CONFIG") -> LiveAccount? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        let store = SessionStore(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        guard let session = try? store.load() else { return nil }
        return LiveAccount(store: store, session: session, manager: SessionManager(session) { try? store.save($0) })
    }

    var client: XRPCClient { XRPCClient(service: session.service, session: manager) }

    /// The account's drive, opened as the device `atdrive login` saved there. It creates the drive
    /// if the account has none (plain, or encrypted with `ATDRIVE_TEST_MODE=encrypted`, dropping
    /// its recovery key), and unlocks an encrypted one this device can't open with
    /// `ATDRIVE_LIVE_RECOVERY_KEY`.
    func openDrive(transfers: TransferOptions = .standard) async throws -> Drive {
        let devices = store.devices
        let drive = Drive(
            client: client, owner: session.did, transfers: transfers,
            identity: try devices.loadOrCreate(name: "atdrive live test"), saveIdentity: { try? devices.save($0) })
        do {
            _ = try await drive.create(encrypted: TestMode.encrypted)
        } catch DriveAccessError.driveExists {
            if (try? await drive.open()) != nil { return drive }
            let text = try #require(
                ProcessInfo.processInfo.environment["ATDRIVE_LIVE_RECOVERY_KEY"],
                "the account's drive is encrypted: set ATDRIVE_LIVE_RECOVERY_KEY to its recovery key")
            try await drive.unlock(recoveryKey: try RecoveryKey(parsing: text))
        }
        return drive
    }
}

/// Starts a real OAuth sign-in against the account's PDS, up to the point where a person would
/// approve it in the browser. Needs only a handle, no password:
///
///     ATDRIVE_LIVE_HANDLE=you.example.com scripts/test.sh --filter OAuthLiveTests
@Suite(.enabled(if: liveHandle() != nil, "set ATDRIVE_LIVE_HANDLE"))
struct OAuthLiveTests {
    @Test func serverAcceptsOurAuthorizationRequest() async throws {
        let handle = try #require(liveHandle())
        let pending = try await OAuthLogin.prepare(identifier: handle, redirectURI: "http://127.0.0.1:43210/")
        // The PDS accepted the client ID, scopes, redirect URI and DPoP proof (else PAR throws).
        let url = pending.authorizationURL.absoluteString
        #expect(url.contains("request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3A"))
        // And the sign-in page it points to loads. (Problems with the request, like a scope the
        // server can't show on its consent screen, come back as a redirect with an error instead.)
        var page = URLRequest(url: pending.authorizationURL)
        let browser = [
            "Accept": "text/html", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Site": "cross-site", "Sec-Fetch-User": "?1",
        ]
        for (name, value) in browser { page.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSessionTransport().send(page)
        #expect(response.statusCode == 200)

    }
}

private func liveHandle() -> String? {
    ProcessInfo.processInfo.environment["ATDRIVE_LIVE_HANDLE"].flatMap { $0.isEmpty ? nil : $0 }
}
