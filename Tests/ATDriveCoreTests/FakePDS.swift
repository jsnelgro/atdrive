import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An in-memory stand-in for the handful of PDS endpoints `Drive` uses, so the drive logic
/// (chunking, verification, paging, auto-creating the space, following the change feed) can be
/// tested without a network. Behaviour against the real server is checked by `LiveTests`.
///
/// Like the reference PDS, every write gets a revision (a TID) and is logged with its index
/// in the commit, its CID and the CID it replaced; `listRepoOps` serves that log with a value
/// only for ops whose version is still current, and the commit once it reaches the head.
final class FakePDS: HTTPTransport, @unchecked Sendable {
    private struct Stored {
        var cid: String
        var json: Data
    }
    private struct Op {
        var rev: String
        var idx: Int
        var collection: String
        var rkey: String
        var cid: String?
        var prev: String?
    }

    private let lock = NSLock()
    private(set) var spaceExists = false
    private(set) var blobs: [String: Data] = [:]
    /// By `collection/rkey`.
    private var records: [String: Stored] = [:]
    private var oplog: [Op] = []
    /// The repo's revision: `nil` until its first write.
    private var rev: String?
    private(set) var calls: [String] = []
    /// Flip a byte in every blob served, to simulate corruption.
    var corruptDownloads = false
    /// Records per listRecords page, to exercise paging.
    var pageSize = 2
    /// The most ops per listRepoOps page (the client's limit applies too), to exercise paging.
    var opsPageSize = 3
    /// Fail the next calls to these methods (e.g. `com.atproto.space.getBlob`) with a 500.
    var failing: [String: Int] = [:]
    /// Serve this many more commits (`Int.max`: every one) with a `data` that matches no
    /// records, as a server that hashes differently would.
    var lyingCommits = 0

    var recordCount: Int { lock.withLock { records.count } }
    /// The repo's current revision.
    var revision: String? { lock.withLock { rev } }
    var opCount: Int { lock.withLock { oplog.count } }

    /// Called with each method name before it's handled (e.g. to change something mid-sync).
    var onRequest: (@Sendable (String) -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onRequest?(request.url!.lastPathComponent)
        return lock.withLock { handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = url.lastPathComponent
        calls.append(method)
        if let remaining = failing[method], remaining > 0 {
            failing[method] = remaining - 1
            return error(500, "InternalServerError")
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            },
            uniquingKeysWith: { a, _ in a })
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]

        switch method {
        case "com.atproto.space.createSpace":
            if spaceExists { return error(400, "SpaceAlreadyExists") }
            spaceExists = true
            return json(["uri": "at://did:plc:test/space/\(body["spaceType"]!)/\(body["skey"]!)"])

        case "com.atproto.repo.uploadBlob":
            let data = request.httpBody ?? Data()
            let cid = CID.forBlob(data)
            blobs[cid] = data
            return json([
                "blob": [
                    "$type": "blob", "ref": ["$link": cid], "mimeType": "application/octet-stream", "size": data.count,
                ]
            ])

        case "com.atproto.space.putRecord":
            guard spaceExists else { return error(400, "SpaceNotFound") }
            let collection = body["collection"] as? String ?? Lexicon.node
            let rkey = body["rkey"] as! String
            let cid = commit([(collection, rkey, body["record"]!)])
            return json(["uri": "at://did:plc:test/\(collection)/\(rkey)", "cid": cid.first!])

        case "com.atproto.space.listRecords":
            guard spaceExists else { return error(400, "SpaceNotFound") }
            let cursor = query["cursor"]
            let collection = query["collection"]
            let keys = records.keys.sorted().filter { key in
                (collection.map { key.hasPrefix($0 + "/") } ?? true) && (cursor.map { key > $0 } ?? true)
            }
            let page = Array(keys.prefix(pageSize))
            var output: [String: Any] = [
                "records": page.map { key in
                    let (collection, rkey) = split(key)
                    return [
                        "collection": collection, "rkey": rkey, "cid": records[key]!.cid,
                        "value": try! JSONSerialization.jsonObject(with: records[key]!.json),
                    ]
                }
            ]
            if keys.count > page.count { output["cursor"] = page.last! }
            return json(output)

        case "com.atproto.space.getBlob":
            guard var data = blobs[query["cid"] ?? ""] else { return error(400, "BlobNotFound") }
            if corruptDownloads, !data.isEmpty { data[0] ^= 0xFF }
            return (data, response(200))

        case "com.atproto.space.applyWrites":
            guard spaceExists else { return error(400, "SpaceNotFound") }
            // One transaction: checked in full before anything is written.
            var writes: [(collection: String, rkey: String, value: Any?)] = []
            var exists = Set(records.keys)
            for write in body["writes"] as! [[String: Any]] {
                let collection = write["collection"] as! String
                let rkey = write["rkey"] as! String
                let key = "\(collection)/\(rkey)"
                switch write["$type"] as? String {
                case "com.atproto.space.applyWrites#delete":
                    guard exists.remove(key) != nil else { return error(400, "RecordNotFound") }
                    writes.append((collection, rkey, nil))
                case "com.atproto.space.applyWrites#create":
                    guard exists.insert(key).inserted else { return error(400, "RecordAlreadyExists") }
                    writes.append((collection, rkey, write["value"]!))
                case "com.atproto.space.applyWrites#update":
                    guard exists.contains(key) else { return error(400, "RecordNotFound") }
                    writes.append((collection, rkey, write["value"]!))
                default:
                    return error(400, "InvalidRequest")
                }
            }
            commit(writes)
            return json([:])

        case "com.atproto.space.getLatestCommit":
            guard let rev else { return error(400, "RepoNotFound") }
            return json(["commit": commitJSON(rev)])

        case "com.atproto.space.listRepoOps":
            // As the reference PDS: no error for a missing space or repo, just no commit.
            var position: (rev: String, idx: Int)?
            if let cursor = query["cursor"] {
                let parts = cursor.split(separator: "/")
                position = (String(parts[0]), Int(parts[1])!)
            } else if let since = query["since"] {
                position = (since, Int.max)
            }
            let limit = min(Int(query["limit"] ?? "100")!, 1000, opsPageSize)
            let after = oplog.filter { op in
                guard let position else { return true }
                return op.rev > position.rev || (op.rev == position.rev && op.idx > position.idx)
            }
            let page = after.prefix(limit)
            var output: [String: Any] = [
                "ops": page.map { op -> [String: Any] in
                    var entry: [String: Any] = [
                        "rev": op.rev, "collection": op.collection, "rkey": op.rkey,
                        "cid": op.cid.map { $0 as Any } ?? NSNull(), "prev": op.prev.map { $0 as Any } ?? NSNull(),
                    ]
                    // Only the record's current value: a version a later op replaced has none.
                    if let cid = op.cid, let stored = records["\(op.collection)/\(op.rkey)"], stored.cid == cid {
                        entry["value"] = try! JSONSerialization.jsonObject(with: stored.json)
                    }
                    return entry
                }
            ]
            // Like the reference: a full page has a cursor and no commit, even at the head.
            if page.count == limit, let last = page.last {
                output["cursor"] = "\(last.rev)/\(last.idx)"
            } else if let rev {
                output["commit"] = commitJSON(rev)
            }
            return json(output)

        default:
            return error(501, "MethodNotImplemented")
        }
    }

    /// Writes records (`nil` deletes) as one commit, logging an op for each. Returns their CIDs.
    @discardableResult
    private func commit(_ writes: [(collection: String, rkey: String, value: Any?)]) -> [String?] {
        let newRev = TID.next()
        var cids: [String?] = []
        for (index, write) in writes.enumerated() {
            let key = "\(write.collection)/\(write.rkey)"
            let prev = records[key]?.cid
            var cid: String?
            if let value = write.value {
                // Content-addressed, like real record CIDs: the same record has the same CID.
                let json = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                cid = "bafyrecord" + CID.forBlob(json).dropFirst(7)
                records[key] = Stored(cid: cid!, json: json)
            } else {
                records[key] = nil
            }
            oplog.append(
                Op(rev: newRev, idx: index, collection: write.collection, rkey: write.rkey, cid: cid, prev: prev))
            cids.append(cid)
        }
        rev = newRev
        return cids
    }

    private func commitJSON(_ rev: String) -> [String: Any] {
        var data = commitData
        if lyingCommits > 0 {
            lyingCommits -= 1
            data[0] ^= 0xFF
        }
        return [
            "ver": 1, "repo": "did:plc:test", "space": "at://did:plc:test/space/\(Lexicon.driveSpace)/default",
            // Unpadded base64, as atproto writes it.
            "rev": rev, "data": ["$bytes": data.base64EncodedString().replacingOccurrences(of: "=", with: "")],
        ]
    }

    /// The LtHash over every current record, as the reference's commit holds. Computed from
    /// scratch each time, whatever wrote the records; the repos here are small.
    private var commitData: Data {
        var hash = RepoSetHash()
        for (key, stored) in records {
            let (collection, rkey) = split(key)
            hash.add(collection: collection, rkey: rkey, cid: stored.cid)
        }
        return hash.setHash.digest
    }

    /// The `data` an honest commit would have now.
    var currentCommitData: Data { lock.withLock { commitData } }

    private func split(_ key: String) -> (collection: String, rkey: String) {
        let slash = key.lastIndex(of: "/")!
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    /// Stores a record exactly as given, bypassing `Drive`, to set up odd states. It goes
    /// through the change feed like any write.
    func insertRawRecord(rkey: String, collection: String = Lexicon.node, _ record: [String: Any]) {
        lock.withLock {
            spaceExists = true
            commit([(collection, rkey, record)])
        }
    }

    /// Deletes a record, bypassing `Drive`.
    func deleteRawRecord(rkey: String, collection: String = Lexicon.node) {
        lock.withLock { _ = commit([(collection, rkey, nil)]) }
    }

    /// The record's CID, if it exists.
    func cid(of rkey: String, collection: String = Lexicon.node) -> String? {
        lock.withLock { records["\(collection)/\(rkey)"]?.cid }
    }

    /// Drops the change feed's ops up to and including `rev`, as a server may.
    func compactOps(through rev: String) {
        lock.withLock { oplog.removeAll { $0.rev <= rev } }
    }

    /// Like `com.atproto.space.clearRecords`: deletes every record and the whole change feed,
    /// leaving the repo at a new revision.
    func clearRecords() {
        lock.withLock {
            records = [:]
            oplog = []
            rev = TID.next()
        }
    }

    /// Deletes the space, as a wiped server would have: records, change feed, repo and blobs.
    func wipe() {
        lock.withLock {
            spaceExists = false
            records = [:]
            oplog = []
            rev = nil
            blobs = [:]
        }
    }

    private func json(_ object: Any) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), response(200))
    }

    private func error(_ status: Int, _ name: String) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: ["error": name, "message": name]), response(status))
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://pds.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// Replays canned responses in order and records the requests it was sent.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String, [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String, [String: String])]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            requests.append(request)
            let (status, body, headers) = responses.removeFirst()
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            )
        }
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("atdrive-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
