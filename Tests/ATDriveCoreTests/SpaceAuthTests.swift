import Crypto
import Foundation
import Testing

@testable import ATDriveCore

/// The spaces protocol's request signatures, MACs and keys, against known answers: the HPKE
/// secret-export vector from the reference's `kem.test.ts`, and encodings and MACs recomputed with
/// Python (`cryptography`, `hmac`).
@Suite struct SpaceAuthTests {
    static func hex(_ text: String) -> Data {
        Data(
            stride(from: 0, to: text.count, by: 2).map {
                UInt8(text[text.index(text.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
            })
    }

    static let kemPrivate = hex("62c3868357a464f8461d03aa0182c7cebcde841036aea7230ddc7339f1088346")

    @Test func encodesP256KeysAsDIDKeys() throws {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Self.kemPrivate)
        let didKey = P256DIDKey.didKey(key.publicKey)
        #expect(didKey == "did:key:zDnaepxWioy4TQi6a94tSHKU4aqQkz6rksDiBfnuiGbwf4i5N")
        #expect(P256DIDKey.publicKey(didKey)?.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(P256DIDKey.publicKey(String(didKey.dropFirst(8)))?.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(P256DIDKey.publicKey("did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK") == nil)  // Ed25519
        #expect(Base58.decode(Base58.encode([0, 0, 1, 2, 255])) == [0, 0, 1, 2, 255])
    }

    @Test func derivesTheSecretHPKEExports() throws {
        // The reference's vector: the syncer's key share is `enc`, the author's KEM key `skRm`.
        let enc = Self.hex(
            "04d804370b7e24b94749eb1dc8df6d4d4a5d75f9effad01739ebcad5c54a40d57aaa8b4190fc124dbde2e4f1e1d1b012a3bc4038157dc29b55533a932306d8d38d"
        )
        let author = try P256.KeyAgreement.PrivateKey(rawRepresentation: Self.kemPrivate)
        let share = try P256.KeyAgreement.PublicKey(x963Representation: enc)
        let secret = try SpaceMAC.secret(keyShare: P256DIDKey.didKey(share), kemKey: author)
        #expect(
            secret.withUnsafeBytes { Data($0) }
                == Self.hex("2060e0558d1b34c10086bc137f849bb79ba59fcdc30544418e35c9cd301f0d0d"))
        // And the reader's half agrees with the host's.
        let request = try SpaceMAC.request(kemKey: author.publicKey)
        let hosts = try SpaceMAC.secret(keyShare: request.keyShare, kemKey: author)
        #expect(hosts == request.secret)
    }

    @Test func macsACommitAsTheReferenceDoes() throws {
        let space = "at://did:example:space/space/app.bsky.group/test"
        let commit = RepoCommit(
            rev: "3kbcq3p7ad400", data: Data(repeating: 1, count: 32), ver: 1, repo: "did:example:alice", space: space)
        let covered = SpaceMAC.commitHeader(commit)
        #expect(
            covered
                == "ver=1, repo=\"did:example:alice\", space=\"\(space)\", rev=\"3kbcq3p7ad400\", data=:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=:"
        )
        let params = "(\"atproto-space-commit\";sf);keyid=\"did:key:zDnaExample\";tag=\"atproto-space-commit\""
        let base = signatureBase(components: SpaceMAC.components, values: [covered], signatureParams: params)
        let mac = HMAC<SHA256>.authenticationCode(for: base, using: SymmetricKey(data: Data(0..<32)))
        #expect(Data(mac).base64EncodedString() == "15D5NbCdiwPuLCJNzdQyHvkuvXjmT4ouomAYc/EEY/w=")
    }

    @Test func verifiesCommitMACsAndRefusesForgeries() throws {
        let author = P256.KeyAgreement.PrivateKey()
        let space = "at://did:plc:alice/space/app.atdrive.drive/abc"
        let commit = RepoCommit(
            rev: "3kbcq3p7ad400", data: Data(repeating: 7, count: 32), ver: 1, repo: "did:plc:alice", space: space)
        let request = try SpaceMAC.request(kemKey: author.publicKey)
        let headers = try SpaceMAC.responseHeaders(
            for: commit, acceptSignature: request.acceptSignature, kemKey: author)
        let lookup = { (name: String) in headers.first { $0.key.lowercased() == name.lowercased() }?.value }
        try SpaceMAC.verify(commit, headers: lookup, request: request, repo: "did:plc:alice", space: space)

        // A different commit in the body, another repo, or a host without the owner's key: refused.
        var other = commit
        other.data = Data(repeating: 8, count: 32)
        #expect(throws: SpaceAuthError.self) {
            try SpaceMAC.verify(other, headers: lookup, request: request, repo: "did:plc:alice", space: space)
        }
        #expect(throws: SpaceAuthError.self) {
            try SpaceMAC.verify(commit, headers: lookup, request: request, repo: "did:plc:mallory", space: space)
        }
        let forged = try SpaceMAC.responseHeaders(
            for: commit, acceptSignature: request.acceptSignature, kemKey: P256.KeyAgreement.PrivateKey())
        #expect(throws: SpaceAuthError.self) {
            try SpaceMAC.verify(
                commit, headers: { name in forged.first { $0.key.lowercased() == name.lowercased() }?.value },
                request: request, repo: "did:plc:alice", space: space)
        }
        #expect(throws: SpaceAuthError.self) {
            try SpaceMAC.verify(commit, headers: { _ in nil }, request: request, repo: "did:plc:alice", space: space)
        }
    }

    /// The host writes the space in its form (`at:space/…`), the reader asks in ATDrive's: the
    /// same space. Another space isn't.
    @Test func aCommitsSpaceMatchesInEitherForm() throws {
        let author = P256.KeyAgreement.PrivateKey()
        let local = "at://did:plc:alice/space/app.atdrive.drive/abc"
        let wire = "at:space/did:plc:alice/app.atdrive.drive/abc"
        let commit = RepoCommit(
            rev: "3kbcq3p7ad400", data: Data(repeating: 7, count: 32), ver: 1, repo: "did:plc:alice", space: wire)
        let request = try SpaceMAC.request(kemKey: author.publicKey)
        let headers = try SpaceMAC.responseHeaders(
            for: commit, acceptSignature: request.acceptSignature, kemKey: author)
        let lookup = { (name: String) in headers.first { $0.key.lowercased() == name.lowercased() }?.value }
        try SpaceMAC.verify(commit, headers: lookup, request: request, repo: "did:plc:alice", space: local)
        try SpaceMAC.verify(commit, headers: lookup, request: request, repo: "did:plc:alice", space: wire)
        #expect(throws: SpaceAuthError.self) {
            try SpaceMAC.verify(
                commit, headers: lookup, request: request, repo: "did:plc:alice",
                space: "at://did:plc:alice/space/app.atdrive.drive/other")
        }
    }

    @Test func signsCredentialRequests() throws {
        let signer = SpaceRequestSigner()
        let headers = try signer.headers(credential: "eyJ.cred.sig", audience: "did:plc:alice")
        #expect(headers["Authorization"] == "Atproto-Space-Credential eyJ.cred.sig")
        #expect(headers["Atproto-Space-Audience"] == "did:plc:alice")
        #expect(
            headers["Signature-Input"]
                == "sig=(\"authorization\" \"atproto-space-audience\");tag=\"atproto-space-credential\"")
        let signature = try #require(headers["Signature"])
        #expect(signature.hasPrefix("sig=:") && signature.hasSuffix(":"))
        #expect(Base64.decode(String(signature.dropFirst(5).dropLast()))?.count == 64)
        #expect(SpaceRequestSigner.verify(headers, key: signer.key.publicKey))
        var changed = headers
        changed["Atproto-Space-Audience"] = "did:plc:bob"
        #expect(!SpaceRequestSigner.verify(changed, key: signer.key.publicKey))
        #expect(!SpaceRequestSigner.verify(headers, key: P256.Signing.PrivateKey().publicKey))
        #expect(signer.didKey.hasPrefix("did:key:zDna"))
    }

    @Test func parsesAndReserializesStructuredFields() throws {
        let text = "a=1, b=\"x \\\"y\\\"\", c=:AQID:, d, e=(\"f\";sf \"g\");tag=\"t\";k=?0, h=tok"
        let parsed = try #require(StructuredField.parseDictionary(text))
        #expect(StructuredField.serialize(parsed) == text)
        #expect(StructuredField.parseDictionary("a=1,") == nil)
        #expect(StructuredField.parseDictionary("A=1") == nil)
    }
}
