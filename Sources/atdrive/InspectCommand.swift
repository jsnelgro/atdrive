import ATDriveCore
import ArgumentParser
import Foundation

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show exactly what your PDS stores for the drive (raw responses).",
        discussion: """
            Prints the PDS's own JSON for the drive's space: the latest commit, every file and
            folder record, and the blobs they reference. Then asks again without credentials, to
            show the drive isn't readable by anyone else.
            """
    )

    func run() async throws {
        let context = try await Context.load()
        let drive = context.drive
        let session = await context.session.session
        print("PDS:   \(session.service.absoluteString)")
        print("Repo:  \(drive.owner) (@\(session.handle))")
        print("Space: \(drive.space)\n")

        let inSpace: [String: String?] = ["space": drive.space, "repo": drive.owner]
        let queries: [(String, String, [String: String?])] = [
            ("Latest commit", "getLatestCommit", inSpace),
            ("Records", "listRecords", inSpace.merging(["collection": Lexicon.node, "limit": "100"]) { a, _ in a }),
            ("Blobs", "listBlobs", inSpace),
        ]
        for (title, method, params) in queries {
            print("== \(title) (com.atproto.space.\(method))")
            do {
                print(Self.pretty(try await drive.client.rawSpaceQuery(method, params)))
            } catch {
                print("error: \(error)")
            }
            print()
        }

        print("== The same records without signing in (should be refused)")
        let anonymous = XRPCClient(service: session.service)
        do {
            _ = try await anonymous.rawSpaceQuery("listRecords", queries[1].2)
            print("!! The PDS returned the records without credentials.")
        } catch {
            print("refused: \(error)")
        }
        print("\n== Your public repo (anyone can read this)")
        for (method, params) in [
            ("com.atproto.repo.describeRepo", ["repo": drive.owner]),
            ("com.atproto.sync.listBlobs", ["did": drive.owner]),
        ] as [(String, [String: String?])] {
            do {
                let data = try await anonymous.queryBytes(method, params)
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if method.hasSuffix("describeRepo") {
                    print("public collections: \(object?["collections"] ?? "?")")
                } else {
                    print("public blobs: \((object?["cids"] as? [Any])?.count ?? 0)")
                }
            } catch {
                print("\(method): \(error)")
            }
        }
    }

    private static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let formatted = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: formatted, as: UTF8.self)
    }
}
