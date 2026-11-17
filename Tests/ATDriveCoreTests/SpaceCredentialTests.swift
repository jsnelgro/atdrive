import Foundation
import Testing

@testable import ATDriveCore

/// Reading other accounts' spaces, as the protocol has it: a delegation token, a credential, signed
/// requests and MAC'd commits (`SpaceCredentials`), against `FakePDS`, which checks each step.
@Suite struct SpaceCredentialTests {
    let pds = FakePDS()
    let owner = FakePDS.defaultDID
    let space = XRPCClient.spaceURI(authority: FakePDS.defaultDID, type: Lexicon.driveSpace, key: "shared1")

    /// A space of the owner's with one record in it.
    func makeSpace(_ policy: SpacePolicy) async throws {
        let client = pds.client()
        try await client.createSpace(type: Lexicon.driveSpace, key: "shared1", policy: policy)
        try await client.putSpaceRecord(
            space: space, repo: owner, collection: Lexicon.settings, rkey: "self", record: ["hello": "world"])
    }

    func read(as reader: String?) async throws -> Int {
        let client = try await pds.access(as: reader).credentials(for: space).client
        let page = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil)
        _ = try await client.latestSpaceCommit(space: space, repo: owner)
        _ = try await client.listRepoOps(space: space, repo: owner, since: nil)
        return page.records.count
    }

    @Test func membersReadAndOthersDont() async throws {
        let bob = pds.addAccount("bob")
        let carol = pds.addAccount("carol")
        try await makeSpace(.members(publicRead: false))
        try await pds.client().putMembers(space, [SpaceMember(did: bob)])

        #expect(try await read(as: bob) == 1)
        await #expect {
            _ = try await read(as: carol)
        } throws: { SpaceAccessProblem($0) == .notShared }
        await #expect {
            _ = try await read(as: nil)
        } throws: { SpaceAccessProblem($0) == .notShared }
        #expect(try await pds.client().listMembers(space).map(\.did) == [bob])
    }

    @Test func aPublicSpaceReadsSignedOut() async throws {
        try await makeSpace(.members(publicRead: true))
        #expect(try await read(as: nil) == 1)
        #expect(pds.count("com.atproto.space.getDelegationToken") == 0)
    }

    @Test func aRemovedMemberLosesAccessAtOnce() async throws {
        let bob = pds.addAccount("bob")
        try await makeSpace(.members(publicRead: false))
        try await pds.client().putMembers(space, [SpaceMember(did: bob)])
        let client = try await pds.access(as: bob).credentials(for: space).client
        #expect(try await client.latestSpaceCommit(space: space, repo: owner) != nil)

        try await pds.client().removeMembers(space, dids: [bob])
        await #expect {
            _ = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil)
        } throws: { SpaceAccessProblem($0) == .notShared }
    }

    @Test func aDeletedSpaceSaysSo() async throws {
        let bob = pds.addAccount("bob")
        try await makeSpace(.members(publicRead: false))
        try await pds.client().putMembers(space, [SpaceMember(did: bob)])
        let client = try await pds.access(as: bob).credentials(for: space).client
        _ = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil)

        try await pds.client().deleteSpace(space)
        await #expect {
            _ = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil)
        } throws: { SpaceAccessProblem($0) == .deleted }
        #expect(!pds.exists(space))
    }

    @Test func anExpiredCredentialIsRenewedOnce() async throws {
        let bob = pds.addAccount("bob")
        try await makeSpace(.members(publicRead: false))
        try await pds.client().putMembers(space, [SpaceMember(did: bob)])
        pds.credentialLifetime = -1  // already expired when issued
        let client = try await pds.access(as: bob).credentials(for: space).client
        await #expect {
            _ = try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil)
        } throws: { ($0 as? XRPCError)?.error == "ExpiredCredential" }
        #expect(pds.count("com.atproto.space.listRecords") == 2, "tried again once, with a new credential")

        pds.credentialLifetime = 600
        #expect(try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil).records.count == 1)
    }

    @Test func refusesCommitsWithoutTheOwnersMAC() async throws {
        try await makeSpace(.members(publicRead: true))
        pds.forgeMACs = true
        let client = try await pds.access(as: nil).credentials(for: space).client
        await #expect(throws: SpaceAuthError.self) {
            _ = try await client.latestSpaceCommit(space: space, repo: owner)
        }
        // Records themselves carry no MAC: the commit (with the LtHash) is what's checked.
        #expect(try await client.listRawSpaceRecords(space: space, repo: owner, collection: nil).records.count == 1)
    }

    @Test func managesSpaces() async throws {
        let client = pds.client()
        try await makeSpace(.members(publicRead: false))
        #expect(try await client.getSpacePolicy(space) == .members(publicRead: false))
        try await client.updateSpace(space, policy: .members(publicRead: true))
        #expect(try await client.getSpacePolicy(space) == .members(publicRead: true))
        #expect(try await client.listSpaces(type: Lexicon.driveSpace) == [space])
        try await client.deleteSpace(space)
        try await client.deleteSpace(space)  // already deleted: fine
        #expect(try await client.listSpaces(type: Lexicon.driveSpace) == [])
        // And it can be made again.
        try await makeSpace(.personal)
        #expect(try await client.listSpaces(type: Lexicon.driveSpace) == [space])
    }

    @Test func publicRecords() async throws {
        let client = pds.client()
        try await client.putPublicRecord(
            repo: owner, collection: "com.example.thing", rkey: "self", record: .object(["a": .integer(1)]))
        let reader = pds.client(as: pds.addAccount("bob"))
        #expect(
            try await reader.getPublicRecord(repo: owner, collection: "com.example.thing", rkey: "self")?["a"]
                == .integer(1))
        try await client.deletePublicRecord(repo: owner, collection: "com.example.thing", rkey: "self")
        #expect(try await reader.getPublicRecord(repo: owner, collection: "com.example.thing", rkey: "self") == nil)
    }
}

@Suite struct ResetTests {
    @Test func deletesEveryATDriveSpaceTheAccountOwnsAndItsSharingKey() async throws {
        let pds = FakePDS()
        let drive = pds.device(keyring: TestMode.keyring())
        _ = try await drive.create(encrypted: TestMode.encrypted)
        _ = try await drive.createFolder(named: "photos", in: nil)
        let client = pds.client()
        let shared = try await client.createSpace(
            type: Lexicon.driveSpace, key: "s1", policy: .members(publicRead: true))
        let other = try await client.createSpace(type: "com.example.board", key: "b1", policy: .personal)
        // Someone else's space stays.
        let bob = pds.addAccount("bob")
        let bobs = try await pds.client(as: bob).createSpace(type: Lexicon.driveSpace, key: "x", policy: .personal)
        try await client.putPublicRecord(
            repo: FakePDS.defaultDID, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey, record: .object([:]))

        let result = try await AccountReset.run(client: client, owner: FakePDS.defaultDID)
        #expect(Set(result.spaces) == [FakePDS.space, shared])
        #expect(result.sharingKey)
        #expect(pds.allSpaces == [bobs, other].sorted())
        #expect(pds.publicRecord(FakePDS.defaultDID, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey) == nil)

        // And a new drive can be made in the same place.
        let fresh = pds.device(keyring: TestMode.keyring())
        _ = try await fresh.create(encrypted: TestMode.encrypted)
        #expect(try await fresh.tree().nodes.isEmpty)
    }
}
