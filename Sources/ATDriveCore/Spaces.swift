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

    public struct SpaceRecordPage<Value: Decodable & Sendable>: Sendable {
        public struct Record: Sendable {
            /// Given when listing every collection.
            public var collection: String?
            public var rkey: String
            public var cid: String
            /// `nil` if the record didn't match `Value` (e.g. written by a newer version).
            public var value: Value?
        }
        public var records: [Record]
        public var cursor: String?
    }

    /// One page of a collection's records, or of every collection's when `collection` is `nil`.
    public func listSpaceRecords<Value: Decodable & Sendable>(
        space: String, repo: String, collection: String?, cursor: String? = nil, limit: Int = 1000,
        as _: Value.Type = Value.self
    ) async throws -> SpaceRecordPage<Value> {
        let output = try await query(
            "com.atproto.space.listRecords",
            [
                "space": space, "repo": repo, "collection": collection, "cursor": cursor,
                "limit": String(limit),
            ], as: ListRecordsOutput<Value>.self)
        return SpaceRecordPage(
            records: output.records.map {
                .init(collection: $0.collection, rkey: $0.rkey, cid: $0.cid, value: $0.value?.value)
            },
            cursor: output.cursor)
    }

    /// One page of records as stored, of any shape: a collection's, or every collection's when
    /// `collection` is `nil`.
    public func listRawSpaceRecords(
        space: String, repo: String, collection: String?, cursor: String? = nil, limit: Int = 1000
    ) async throws -> SpaceRecordPage<JSONValue> {
        let method = "com.atproto.space.listRecords"
        let output = try await queryJSON(
            method,
            [
                "space": space, "repo": repo, "collection": collection, "cursor": cursor,
                "limit": String(limit),
            ])
        guard let items = output["records"]?.array else { throw Self.malformed(method) }
        return SpaceRecordPage(
            records: try items.map { item in
                guard let rkey = item["rkey"]?.string, let cid = item["cid"]?.string else {
                    throw Self.malformed(method)
                }
                return .init(
                    collection: item["collection"]?.string, rkey: rkey, cid: cid, value: item["value"].unlessNull)
            },
            cursor: output["cursor"]?.string)
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
        try await latestSpaceCommit(space: space, repo: repo)?.rev
    }

    /// The repo's current commit in the space, or `nil` if it holds no repo there (never written
    /// to, or the space is gone).
    public func latestSpaceCommit(space: String, repo: String) async throws -> RepoCommit? {
        struct Output: Decodable { var commit: RepoCommit }
        do {
            return try await query(
                "com.atproto.space.getLatestCommit", ["space": space, "repo": repo], as: Output.self
            ).commit
        } catch let error as XRPCError where error.error == "RepoNotFound" || error.error == "SpaceNotFound" {
            return nil
        }
    }

    /// One page of the repo's change feed: the writes after `since` (or after `cursor`, which
    /// takes precedence), in every collection, in order. A page holds up to `limit` ops (the
    /// server allows 1000). The last one has no cursor and carries the commit, unless the repo
    /// doesn't exist. The server may compact the feed, so it isn't history: `prev` shows gaps.
    public func listRepoOps(
        space: String, repo: String, since: String?, cursor: String? = nil, limit: Int = 1000
    ) async throws -> RepoOpsPage {
        let method = "com.atproto.space.listRepoOps"
        let output = try await queryJSON(
            method, ["space": space, "repo": repo, "since": since, "cursor": cursor, "limit": String(limit)])
        guard let items = output["ops"]?.array else { throw Self.malformed(method) }
        let ops = try items.map { item in
            guard let rev = item["rev"]?.string, let collection = item["collection"]?.string,
                let rkey = item["rkey"]?.string
            else { throw Self.malformed(method) }
            return RepoOp(
                rev: rev, collection: collection, rkey: rkey, cid: item["cid"]?.string, prev: item["prev"]?.string,
                value: item["value"].unlessNull)
        }
        var commit: RepoCommit?
        if let value = output["commit"].unlessNull {
            do { commit = try value.decode(as: RepoCommit.self) } catch { throw Self.malformed(method) }
        }
        return RepoOpsPage(ops: ops, commit: commit, cursor: output["cursor"]?.string)
    }

    /// A query's JSON output as a `JSONValue`, for outputs holding records of any shape.
    private func queryJSON(_ method: String, _ params: [String: String?]) async throws -> JSONValue {
        let data = try await queryBytes(method, params)
        guard let output = try? JSONValue(parsing: data), case .object = output else { throw Self.malformed(method) }
        return output
    }

    private static func malformed(_ method: String) -> ATDriveError {
        .unexpectedResponse("\(method): the output isn't what its lexicon says")
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
        var collection: String?
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

/// One write in a repo's change feed (`listRepoOps`), in any collection.
public struct RepoOp: Sendable, Equatable {
    /// The commit it was part of. Ops with the same rev were written together, in order.
    public var rev: String
    public var collection: String
    public var rkey: String
    /// The record's CID after this op; `nil` for a delete.
    public var cid: String?
    /// The record's CID before this op; `nil` for a create.
    public var prev: String?
    /// The record's value, only while this op's version is still the current one: an op a
    /// later one replaced comes without it.
    public var value: JSONValue?

    public init(
        rev: String, collection: String, rkey: String, cid: String?, prev: String?, value: JSONValue? = nil
    ) {
        self.rev = rev
        self.collection = collection
        self.rkey = rkey
        self.cid = cid
        self.prev = prev
        self.value = value
    }
}

/// A repo's commit in a space. There's no Merkle tree: `data` is a SHA-256 of an LtHash over
/// every record (`collection/rkey/cid`), so a client holding the same records can check it.
public struct RepoCommit: Sendable, Equatable, Codable {
    public var rev: String
    /// 32 bytes. JSON carries it as `{"$bytes": "<base64>"}`.
    public var data: Data

    public init(rev: String, data: Data) {
        self.rev = rev
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case rev, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decode(String.self, forKey: .rev)
        data = try container.decode(Bytes.self, forKey: .data).data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        try container.encode(Bytes(data), forKey: .data)
    }
}

public struct RepoOpsPage: Sendable {
    public var ops: [RepoOp]
    /// On the last page (the head of the feed), unless the repo doesn't exist.
    public var commit: RepoCommit?
    /// Absent on the last page.
    public var cursor: String?
}

/// Decodes to `nil` instead of failing, so one odd record can't break a whole listing.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
