import Foundation

/// Typed wrappers for the parts of atproto spaces (`com.atproto.space.*`) ATDrive uses.
/// The spaces API is alpha and changes weekly; keep every call to it in this file.
extension XRPCClient {
    /// `at://<authority-did>/space/<space-type>/<space-key>`
    public static func spaceURI(authority: String, type: String, key: String) -> String {
        "at://\(authority)/space/\(type)/\(key)"
    }

    /// Creates a space only the authenticated account can read or write.
    public func createPersonalSpace(type: String, key: String) async throws -> String {
        struct Policy: Encodable {
            let type = Lexicon.personalSpacePolicy
            enum CodingKeys: String, CodingKey { case type = "$type" }
        }
        struct Input: Encodable {
            var spaceType: String
            var skey: String
            var policy = Policy()
        }
        struct Output: Decodable { var uri: String }
        return try await procedure(
            "com.atproto.space.createSpace", Input(spaceType: type, skey: key), as: Output.self
        ).uri
    }

    /// Creates a drive's space (`at://<did>/space/<type>/<key>`), if it doesn't exist yet.
    func createDriveSpace(_ space: String) async throws {
        let parts = space.split(separator: "/")
        do {
            _ = try await createPersonalSpace(type: String(parts[parts.count - 2]), key: String(parts.last!))
        } catch let error as XRPCError where error.error == "SpaceAlreadyExists" {}
    }

    public struct SpaceRecordPage<Value: Decodable & Sendable>: Sendable {
        public struct Record: Sendable {
            public var rkey: String
            public var cid: String
            /// `nil` if the record didn't match `Value` (e.g. written by a newer version).
            public var value: Value?
        }
        public var records: [Record]
        public var cursor: String?
    }

    public func listSpaceRecords<Value: Decodable & Sendable>(
        space: String, repo: String, collection: String, cursor: String? = nil, limit: Int = 1000,
        as _: Value.Type = Value.self
    ) async throws -> SpaceRecordPage<Value> {
        let output = try await query(
            "com.atproto.space.listRecords",
            [
                "space": space, "repo": repo, "collection": collection, "cursor": cursor,
                "limit": String(limit),
            ], as: ListRecordsOutput<Value>.self)
        return SpaceRecordPage(
            records: output.records.map { .init(rkey: $0.rkey, cid: $0.cid, value: $0.value?.value) },
            cursor: output.cursor)
    }

    /// Creates or replaces a record. Returns its new CID.
    @discardableResult
    public func putSpaceRecord(
        space: String, repo: String, collection: String, rkey: String,
        record: some Encodable & Sendable
    ) async throws -> String {
        try await procedure(
            "com.atproto.space.putRecord",
            PutRecordInput(space: space, repo: repo, collection: collection, rkey: rkey, record: record),
            as: PutRecordOutput.self
        ).cid
    }

    /// Creates a record that must not exist yet: fails with `RecordAlreadyExists` if it does, so
    /// of several devices creating the same record, exactly one succeeds. Returns its CID.
    @discardableResult
    public func createSpaceRecord(
        space: String, repo: String, collection: String, rkey: String,
        record: some Encodable & Sendable
    ) async throws -> String {
        try await procedure(
            "com.atproto.space.createRecord",
            PutRecordInput(space: space, repo: repo, collection: collection, rkey: rkey, record: record),
            as: PutRecordOutput.self
        ).cid
    }

    /// Deletes records in one transaction per 200 (the server's batch limit).
    public func deleteSpaceRecords(space: String, repo: String, collection: String, rkeys: [String])
        async throws
    {
        struct Delete: Encodable {
            let type = "com.atproto.space.applyWrites#delete"
            var collection: String
            var rkey: String
            enum CodingKeys: String, CodingKey {
                case type = "$type"
                case collection, rkey
            }
        }
        struct Input: Encodable {
            var space: String
            var repo: String
            var writes: [Delete]
        }
        for start in stride(from: 0, to: rkeys.count, by: 200) {
            let batch = rkeys[start..<min(start + 200, rkeys.count)]
            let _: Empty = try await procedure(
                "com.atproto.space.applyWrites",
                Input(
                    space: space, repo: repo,
                    writes: batch.map { Delete(collection: collection, rkey: $0) }))
        }
    }

    /// Fetches a blob referenced by a record in the space.
    public func getSpaceBlob(space: String, repo: String, cid: String) async throws -> Data {
        try await queryBytes("com.atproto.space.getBlob", ["space": space, "repo": repo, "cid": cid])
    }

    /// The repo's current revision in the space, or `nil` if it holds no repo there yet.
    public func latestSpaceRevision(space: String, repo: String) async throws -> String? {
        struct Output: Decodable {
            struct Commit: Decodable { var rev: String }
            var commit: Commit
        }
        do {
            return try await query(
                "com.atproto.space.getLatestCommit", ["space": space, "repo": repo], as: Output.self
            ).commit.rev
        } catch let error as XRPCError where error.error == "RepoNotFound" || error.error == "SpaceNotFound" {
            return nil
        }
    }

    /// Uploads bytes to the account's PDS. They stay private until a space record references
    /// them, and are garbage-collected if nothing ever does.
    public func uploadBlob(_ data: Data, mimeType: String) async throws -> BlobRef {
        struct Output: Decodable { var blob: BlobRef }
        return try await procedure(
            "com.atproto.repo.uploadBlob", bytes: data, contentType: mimeType, as: Output.self
        ).blob
    }
}

private struct ListRecordsOutput<Value: Decodable>: Decodable {
    struct Item: Decodable {
        var rkey: String
        var cid: String
        var value: Lenient<Value>?
    }
    var records: [Item]
    var cursor: String?
}

private struct PutRecordOutput: Decodable { var cid: String }

private struct PutRecordInput<Record: Encodable>: Encodable {
    var space: String
    var repo: String
    var collection: String
    var rkey: String
    var validate = false
    var record: Record
}

/// Decodes to `nil` instead of failing, so one odd record can't break a whole listing.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
