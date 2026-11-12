import Crypto
import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// End-to-end against a real spaces-enabled PDS. Skipped unless both are set:
///
///     ATDRIVE_LIVE_HANDLE=you.example.com ATDRIVE_LIVE_PASSWORD=xxxx-xxxx-xxxx-xxxx \
///         scripts/test.sh --filter LiveTests
///
/// It uses a drive of its own (space key `live-test`), encrypted with a key made from the
/// password, so it never touches your real drive. Everything happens inside a uniquely named
/// folder that is deleted at the end.
@Suite(.enabled(if: liveCredentials() != nil, "set ATDRIVE_LIVE_HANDLE and ATDRIVE_LIVE_PASSWORD"))
struct LiveTests {
    @Test func roundTrip() async throws {
        let (handle, password) = try #require(liveCredentials())
        let session = try await Auth.login(identifier: handle, password: password, resolver: IdentityResolver())
        let manager = SessionManager(session)
        // Small chunks so a modest file still spans several blobs.
        let drive = Drive(
            client: XRPCClient(service: session.service, session: manager), owner: session.did,
            driveKey: try DriveKey(rawValue: Data(SHA256.hash(data: Data("atdrive live test \(password)".utf8)))),
            key: "live-test", chunkSize: 64 * 1024)

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
