import ATDriveCore
import ArgumentParser
import Foundation

struct Lexicons: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Publish ATDrive's lexicons (for its maintainer).", subcommands: [LexiconsPublish.self])
}

struct LexiconsPublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish", abstract: "Publish ATDrive's lexicons as schema records, so PDSes can resolve them.",
        discussion: """
            Signs in as <handle> (just for this: asking only to write schema records) and writes each lexicon in the folder as a com.atproto.lexicon.schema record, keyed by its NSID. Then add the DNS record it prints, which says that account publishes them. Once a PDS resolves them, OAuthLogin.lexiconsPublished can be set, and sign-in asks for ATDrive's spaces only.
            """)

    @Argument(help: "The account that publishes them.")
    var handle: String

    @Option(help: "The folder of lexicon JSON files.")
    var directory = "lexicons"

    /// Every lexicon in the folder, as a schema record, by NSID. (Synchronous: the directory
    /// enumerator can't be iterated from async code on macOS.)
    static func schemas(in directory: String) throws -> [(id: String, value: JSONValue)] {
        let root = URL(fileURLWithPath: directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ValidationError("no folder at \(directory)")
        }
        var schemas: [(id: String, value: JSONValue)] = []
        while let file = walker.nextObject() as? URL {
            guard file.pathExtension == "json" else { continue }
            let value = try JSONValue(parsing: Data(contentsOf: file))
            guard case .object(var object) = value, let id = object["id"]?.string else { continue }
            object["$type"] = .string("com.atproto.lexicon.schema")
            schemas.append((id, .object(object)))
        }
        return schemas
    }

    func run() async throws {
        let schemas = try Self.schemas(in: directory)
        guard !schemas.isEmpty else { throw ValidationError("no lexicons in \(directory)") }
        let scope = "atproto repo:com.atproto.lexicon.schema"
        let session = try await OAuthLogin.signIn(
            identifier: handle, environment: ["ATDRIVE_OAUTH_SCOPE": scope],
            open: { url in print("Sign in as \(handle) to publish:\n\n  \(url.absoluteString)\n") })
        let client = XRPCClient(service: session.service, session: SessionManager(session))
        for (id, value) in schemas.sorted(by: { $0.id < $1.id }) {
            try await client.putPublicRecord(
                repo: session.did, collection: "com.atproto.lexicon.schema", rkey: id, record: value)
            print("✓ \(id)")
        }
        await Auth.logout(session)
        let authorities = Set(
            schemas.map { id, _ in
                id.split(separator: ".").dropLast().reversed().joined(separator: ".")
            })
        print("\nNow add this DNS record\(authorities.count == 1 ? "" : "s") (TXT):")
        for authority in authorities.sorted() { print("  _lexicon.\(authority)  \"did=\(session.did)\"") }
    }
}
