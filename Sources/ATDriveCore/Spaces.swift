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
    /// List as `JSONValue` to get records of any shape.
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
        struct Output: Decodable {
            var ops: [RepoOp]
            var commit: RepoCommit?
            var cursor: String?
        }
        let output = try await query(
            "com.atproto.space.listRepoOps",
            ["space": space, "repo": repo, "since": since, "cursor": cursor, "limit": String(limit)],
            as: Output.self)
        return RepoOpsPage(ops: output.ops, commit: output.commit, cursor: output.cursor)
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
public struct RepoOp: Sendable, Equatable, Decodable {
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
        try container.encode(Bytes(data: data), forKey: .data)
    }
}

public struct RepoOpsPage: Sendable {
    public var ops: [RepoOp]
    /// On the last page (the head of the feed), unless the repo doesn't exist.
    public var commit: RepoCommit?
    /// Absent on the last page.
    public var cursor: String?
}

/// atproto's JSON form of bytes: `{"$bytes": "<base64>"}`, without padding (accepted with).
struct Bytes: Codable {
    var data: Data
    private enum CodingKeys: String, CodingKey { case bytes = "$bytes" }

    init(data: Data) { self.data = data }

    init(from decoder: Decoder) throws {
        var text = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .bytes)
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad base64"))
        }
        self.data = data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data.base64EncodedString().replacingOccurrences(of: "=", with: ""), forKey: .bytes)
    }
}

/// Any JSON value: a record as stored, before it's decoded (or, later, decrypted) as a type, or
/// a record of a collection this version doesn't model. atproto has no floats, so whole numbers
/// stay exact.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// This value decoded as a `T`, e.g. a record type.
    public func decode<T: Decodable>(as _: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// A value's JSON form.
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

/// Decodes to `nil` instead of failing, so one odd record can't break a whole listing.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
