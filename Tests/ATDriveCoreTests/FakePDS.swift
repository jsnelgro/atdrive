import Foundation
import Testing

@testable import ATDriveCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An in-memory stand-in for the handful of PDS endpoints `Drive` uses, so the drive logic
/// (chunking, verification, paging, auto-creating the space) can be tested without a network.
/// It is deliberately simple; behaviour against the real server is checked by `LiveTests`.
final class FakePDS: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spaceExists = false
    private(set) var blobs: [String: Data] = [:]
    /// Keyed by "<collection>/<rkey>".
    private var records: [String: (cid: String, json: Data)] = [:]
    private var recordVersion = 0
    private(set) var calls: [String] = []
    /// Flip a byte in every blob served, to simulate corruption.
    var corruptDownloads = false
    /// Records per listRecords page, to exercise paging.
    var pageSize = 2
    /// Fail the next calls to these methods (e.g. `com.atproto.space.getBlob`) with a 500.
    var failing: [String: Int] = [:]

    /// Node records (files and folders).
    var recordCount: Int { lock.withLock { records.keys.filter { $0.hasPrefix(Lexicon.node + "/") }.count } }

    /// A record as stored, or `nil`.
    func rawRecord(_ collection: String, _ rkey: String) -> [String: Any]? {
        lock.withLock {
            records["\(collection)/\(rkey)"].flatMap {
                try? JSONSerialization.jsonObject(with: $0.json) as? [String: Any]
            }
        }
    }

    /// Every record and blob as stored, as one string, to check nothing private is readable.
    var everythingStored: Data {
        lock.withLock { records.values.map(\.json).reduce(Data(), +) + blobs.values.reduce(Data(), +) }
    }

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

        case "com.atproto.space.putRecord", "com.atproto.space.createRecord":
            guard spaceExists else { return error(400, "SpaceNotFound") }
            let rkey = body["rkey"] as! String
            let key = "\(body["collection"] as! String)/\(rkey)"
            if method.hasSuffix("createRecord"), records[key] != nil { return error(400, "RecordAlreadyExists") }
            recordVersion += 1
            let cid = "bafyrecord\(recordVersion)"
            records[key] = (cid, try! JSONSerialization.data(withJSONObject: body["record"]!))
            return json(["uri": "at://did:plc:test/x/\(rkey)", "cid": cid])

        case "com.atproto.space.listRecords":
            guard spaceExists else { return error(400, "SpaceNotFound") }
            let collection = query["collection"] ?? ""
            let cursor = query["cursor"]
            let keys = records.keys.filter { $0.hasPrefix(collection + "/") }
                .map { String($0.dropFirst(collection.count + 1)) }
                .sorted().filter { key in cursor.map { key > $0 } ?? true }
            let page = Array(keys.prefix(pageSize))
            var output: [String: Any] = [
                "records": page.map { rkey in
                    let record = records["\(collection)/\(rkey)"]!
                    return [
                        "collection": collection, "rkey": rkey, "cid": record.cid,
                        "value": try! JSONSerialization.jsonObject(with: record.json),
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
            for write in body["writes"] as! [[String: Any]] {
                records["\(write["collection"] as! String)/\(write["rkey"] as! String)"] = nil
            }
            recordVersion += 1
            return json([:])

        case "com.atproto.space.getLatestCommit":
            guard spaceExists else { return error(400, "RepoNotFound") }
            return json(["commit": ["cid": "bafycommit\(recordVersion)", "rev": "rev\(recordVersion)"]])

        default:
            return error(501, "MethodNotImplemented")
        }
    }

    /// Stores a record exactly as given, bypassing `Drive`, to set up odd states.
    func insertRawRecord(_ collection: String = Lexicon.node, rkey: String, _ record: [String: Any]) {
        lock.withLock {
            spaceExists = true
            recordVersion += 1
            records["\(collection)/\(rkey)"] = (
                "bafyrecord\(recordVersion)", try! JSONSerialization.data(withJSONObject: record)
            )
        }
    }

    /// Stores a blob exactly as given (e.g. an unencrypted one, as older versions wrote).
    func insertRawBlob(_ data: Data) -> String {
        lock.withLock {
            let cid = CID.forBlob(data)
            blobs[cid] = data
            return cid
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
