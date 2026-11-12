import Crypto
import Foundation
import Testing

@testable import ATDriveCore

@Suite struct EncryptionTests {
    let pds = FakePDS()
    let client: XRPCClient
    let drive: Drive
    let directory: URL

    init() throws {
        client = XRPCClient(service: URL(string: "https://pds.test")!, transport: pds)
        drive = Drive(client: client, owner: "did:plc:test", driveKey: DriveKey.random(), chunkSize: 4)
        directory = try temporaryDirectory()
    }

    func localFile(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: What the PDS sees

    @Test func thePDSStoresNothingReadable() async throws {
        let folder = try await drive.createFolder(named: "Secret plans", in: nil)
        let file = try await drive.upload(
            try localFile("x", "attack at dawn"), as: "world-domination.txt", in: folder.id)

        let stored = String(decoding: pds.everythingStored, as: UTF8.self)
        for secret in ["Secret plans", "world-domination", "attack", "dawn", file.record.sha256!, folder.id] {
            #expect(!stored.contains(secret), "\(secret) is readable on the PDS")
        }
        // Only the blob refs stay readable, so the PDS keeps the blobs.
        let raw = try #require(pds.rawRecord(Lexicon.node, file.id))
        #expect(Set(raw.keys) == ["$type", "keyID", "sealed", "chunks"])
        #expect((raw["chunks"] as? [Any])?.count == 4)

        // And it all reads back.
        let tree = try await drive.tree()
        let listed = try #require(try tree.locate(DrivePath("/Secret plans/world-domination.txt")))
        #expect(listed.record == file.record)
        let out = directory.appendingPathComponent("out")
        try await drive.download(listed, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "attack at dawn")
    }

    @Test func anotherKeyCantReadTheDrive() async throws {
        try await drive.createFolder(named: "mine", in: nil)
        let stranger = Drive(client: client, owner: "did:plc:test", driveKey: DriveKey.random())
        // Fails loudly, rather than showing an empty drive (which sync would take as deletes).
        await #expect(throws: ATDriveError.self) { try await stranger.tree() }
        do {
            _ = try await stranger.tree()
        } catch {
            #expect(String(describing: error).contains("different key"))
        }
    }

    @Test func tamperingIsDetected() async throws {
        let a = try await drive.createFolder(named: "a", in: nil)
        let b = try await drive.createFolder(named: "b", in: nil)

        // The PDS moves a's sealed contents onto b's record.
        var swapped = try #require(pds.rawRecord(Lexicon.node, a.id))
        pds.insertRawRecord(rkey: b.id, swapped)
        await #expect(throws: ATDriveError.self) { try await drive.tree() }

        // Or flips a byte.
        pds.insertRawRecord(rkey: b.id, try #require(pds.rawRecord(Lexicon.node, b.id)))
        var sealed = try #require((swapped["sealed"] as? [String: String])?["$bytes"])
        sealed = String(sealed.prefix(20)) + (sealed.dropFirst(20).first == "A" ? "B" : "A") + sealed.dropFirst(21)
        swapped["sealed"] = ["$bytes": sealed]
        pds.insertRawRecord(rkey: a.id, swapped)
        do {
            _ = try await drive.tree()
            Issue.record("a changed record was accepted")
        } catch {
            #expect(String(describing: error).contains("changed on the server"))
        }
    }

    @Test func swappedChunksAreDetected() async throws {
        let one = try await drive.upload(try localFile("1", "first file"), as: "1", in: nil)
        let two = try await drive.upload(try localFile("2", "other file"), as: "2", in: nil)
        var raw = try #require(pds.rawRecord(Lexicon.node, one.id))
        raw["chunks"] = pds.rawRecord(Lexicon.node, two.id)?["chunks"]
        pds.insertRawRecord(rkey: one.id, raw)
        await #expect(throws: ATDriveError.self) { try await drive.tree() }
    }

    @Test func encryptsDrivesFromBeforeEncryption() async throws {
        // As an older version wrote them: plaintext records and blobs.
        let cid = pds.insertRawBlob(Data("old contents".utf8))
        let folderID = TID.next()
        pds.insertRawRecord(
            rkey: folderID,
            ["$type": Lexicon.node, "name": "old", "kind": "folder", "createdAt": "2026-01-01T00:00:00Z"])
        let fileID = TID.next()
        pds.insertRawRecord(
            rkey: fileID,
            [
                "$type": Lexicon.node, "name": "notes.txt", "parent": folderID, "kind": "file", "size": 12,
                "sha256": SHA256.hash(data: Data("old contents".utf8)).hexString,
                "chunks": [
                    ["$type": "blob", "ref": ["$link": cid], "mimeType": "application/octet-stream", "size": 12]
                ],
                "createdAt": "2026-01-01T00:00:00Z", "modifiedAt": "2026-01-02T00:00:00Z",
            ])

        do {
            _ = try await drive.tree()
            Issue.record("unencrypted items were listed")
        } catch {
            #expect(String(describing: error).contains("before ATDrive encrypted drives"))
        }

        #expect(try await drive.encryptOlderItems() == 2)
        #expect(try await drive.encryptOlderItems() == 0)  // nothing left
        let tree = try await drive.tree()
        let file = try #require(try tree.locate(DrivePath("/old/notes.txt")))
        #expect(file.id == fileID)
        #expect(file.record.modifiedAt == "2026-01-02T00:00:00Z")
        #expect(file.record.chunks?.first?.cid != cid)
        let out = directory.appendingPathComponent("out")
        try await drive.download(file, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "old contents")
        let raw = try #require(pds.rawRecord(Lexicon.node, fileID))
        #expect(raw["name"] == nil)
    }

    // MARK: Unlocking with a passkey

    @Test func setsUpThenUnlocksWithThePasskey() async throws {
        let passkey = PasskeyResult(credentialID: "Y3JlZC0x", prf: Data(repeating: 7, count: 32))

        let setup = try await DriveUnlock.prepare(client: client, owner: "did:plc:test")
        #expect(setup.mode == .create)
        let key = try await setup.finish(with: passkey)
        let record = try #require(pds.rawRecord(Lexicon.key, DriveUnlock.firstKeyRecord))
        #expect(record["credentialID"] as? String == "Y3JlZC0x")
        #expect(!String(decoding: pds.everythingStored, as: UTF8.self).contains(key.rawValue.base64EncodedString()))

        let later = try await DriveUnlock.prepare(client: client, owner: "did:plc:test")
        #expect(later.mode == .unlock)
        #expect(later.credentialIDs == ["Y3JlZC0x"])
        #expect(try await later.finish(with: passkey) == key)

        // Another passkey, or the same one with different PRF output, can't.
        await #expect(throws: ATDriveError.self) {
            try await later.finish(with: PasskeyResult(credentialID: "b3RoZXI", prf: passkey.prf))
        }
        await #expect(throws: ATDriveError.self) {
            try await later.finish(with: PasskeyResult(credentialID: "Y3JlZC0x", prf: Data(repeating: 8, count: 32)))
        }
    }

    @Test func twoDevicesSettingUpAtOnceGetOneKey() async throws {
        let first = try await DriveUnlock.prepare(client: client, owner: "did:plc:test")
        let second = try await DriveUnlock.prepare(client: client, owner: "did:plc:test")
        _ = try await first.finish(with: PasskeyResult(credentialID: "YQ", prf: Data(repeating: 1, count: 32)))
        await #expect(throws: ATDriveError.self) {
            try await second.finish(with: PasskeyResult(credentialID: "Yg", prf: Data(repeating: 2, count: 32)))
        }
    }

    @Test func wontMakeANewKeyForAnEncryptedDrive() async throws {
        // Encrypted items, but the key record is gone: a new key couldn't open them.
        try await drive.createFolder(named: "x", in: nil)
        await #expect(throws: ATDriveError.self) {
            _ = try await DriveUnlock.prepare(client: client, owner: "did:plc:test")
        }
    }

    // MARK: The unlock page's answer

    /// Sealed by web/unlock/unlock.js (`seal`) under Node's WebCrypto, so this checks the page
    /// and the app agree on the format.
    @Test func opensWhatTheUnlockPageSeals() throws {
        let key = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try #require(Base64URL.decode("Rk_jhkrQHKXrYHiBXKTdiupYR0XZRTShkZXzPC_xFpg")))
        let sealed =
            "BOmoqa_JH3mXgXO_vwSLR58WMdiHSaS90C9dNQo_zdz4V47cTnSVYru0GmifMSYdFH5PIRYyIV8FYcJ6gEFUmK6W0mLMjG5TIV0sF4ipKgB3GAJaKTfjPfI9hTAawr_KHJ55A0Xhj4kPdeae0B4Rp0VBh__BVl8wB7P9OQT_NUhXQc9G0bgUA1VInBTApox1KkzqGwm9tiQIHxL-UfQM1-Owq5SB2_oDxIwvM_wLLgax4GMZ"
        let result = try PasskeyRequest(key: key, state: "state-123").open(sealed)
        #expect(result.credentialID == "Y3JlZGVudGlhbC0x")
        #expect(result.prf == Data(0..<32))

        // Bound to the request's state and key.
        #expect(throws: ATDriveError.self) { try PasskeyRequest(key: key, state: "state-456").open(sealed) }
        #expect(throws: ATDriveError.self) { try PasskeyRequest().open(sealed) }
    }

    @Test func readsThePagesAnswer() throws {
        let page = FakeUnlockPage(credentialID: "Y3JlZC0x", prf: Data(repeating: 9, count: 32))
        let request = PasskeyRequest()
        let unlock = DriveUnlock(
            mode: .create, client: client, owner: "did:plc:test", space: drive.space, keys: [])
        let url = request.pageURL(
            page: URL(string: "https://unlock.test/unlock/")!, unlock: unlock, did: "did:plc:test",
            handle: "alice.test", returnTo: URL(string: "http://127.0.0.1:5555/unlocked")!)
        // Everything is in the fragment, which browsers don't send to the page's server.
        #expect(url.query == nil)
        #expect(url.absoluteString.hasPrefix("https://unlock.test/unlock/#v=1&mode=create&did=did%3Aplc%3Atest"))

        let answer = try page.answer(url)
        #expect(answer.hasPrefix("http://127.0.0.1:5555/unlocked?state="))
        let params = try #require(PasskeyRequest.answer(fromPasted: "  " + answer.dropFirst(7) + "\n"))
        let result = try request.result(from: params)
        #expect(result.credentialID == "Y3JlZC0x")
        #expect(result.prf == Data(repeating: 9, count: 32))

        #expect(throws: ATDriveError.self) { try request.result(from: ["state": request.state, "error": "cancelled"]) }
        #expect(PasskeyRequest.answer(fromPasted: "http://127.0.0.1:1/?code=x&state=y") == nil)
    }
}

/// Does what web/unlock/unlock.js does once the passkey has answered.
struct FakeUnlockPage {
    var credentialID: String
    var prf: Data

    /// The page's fragment, as the app wrote it.
    func request(_ url: URL) throws -> [String: String] {
        let items = try #require(URLComponents(string: "x:?" + (url.fragment ?? ""))?.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// Where the page sends the browser: back to the app, with the sealed result.
    func answer(_ url: URL) throws -> String {
        let params = try request(url)
        let state = try #require(params["state"])
        let appKey = try P256.KeyAgreement.PublicKey(x963Representation: try #require(Base64URL.decode(params["pk"]!)))
        let ours = P256.KeyAgreement.PrivateKey()
        let aesKey = try ours.sharedSecretFromKeyAgreement(with: appKey).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ours.publicKey.x963Representation + appKey.x963Representation,
            sharedInfo: Data("atdrive unlock v1".utf8), outputByteCount: 32)
        let payload = try JSONSerialization.data(withJSONObject: [
            "credentialID": credentialID, "prf": Base64URL.encode(prf),
        ])
        let box = try AES.GCM.seal(payload, using: aesKey, authenticating: Data(state.utf8))
        let result = Base64URL.encode(ours.publicKey.x963Representation + box.combined!)
        return "\(params["return"]!)?state=\(state)&result=\(result)"
    }
}
