import ATDriveCore
import ArgumentParser
import Foundation

struct Spaces: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the spaces in your Spaces folder: other apps' data, and spaces shared with you.",
        discussion: """
            Other atproto apps keep data in spaces too (a Bulletin board's notes, say), and people share spaces with you. With Spaces on, all of it is in a read-only folder at the top of your drive, by app, then space, then record type:

              /Spaces/Bulletin/home/note/3l2kabc.json                 yours, in your board
              /Spaces/Bulletin/home/note/@bob.test 3l2mxyz.json       someone else's, in it too
              /Spaces/Bulletin/@carol.test kitchen/note/…             a board someone else owns

            Use it like the rest of your drive (ls, cat, get, a synced folder, Finder); it just can't be changed. Records are JSON as stored; the files a record references are beside it, in <record>.blobs/.

            This lists each space: where it is, its address, and whether it can be read. Everything is set in config.toml (`atdrive config` shows where):

              [spaces]
              enabled = true
              folder = "Spaces"
              include = ["at://carol.test/space/my.bulletin.board/kitchen"]   # shared with you, never written to
              exclude = ["at://alice.test/space/com.example.noisy/x"]         # not shown

            Spaces you own or have written to show up by themselves. One shared with you that you've never written to doesn't (atproto can't list those yet), so include it by its address.
            """
    )

    func run() async throws {
        guard let settings = try ConfigFile.standard().load().spaces else { throw SpaceDataError.off }
        let context = try await Context.load()
        Output.status("Reading your spaces…")
        let snapshot = try await context.joined.update(nil)
        Output.clearStatus()
        guard let folder = snapshot.spaces else { throw SpaceDataError.off }
        if let problem = folder.problem { Output.warn("couldn't read your spaces: \(problem)") }
        guard let read = folder.snapshot else { return }
        let tree = snapshot.tree
        let place = tree.nodes[SpacesFolder.id].map { tree.path(of: $0).description } ?? "/\(settings.folder)"
        print("Spaces is \(place) in your drive.")
        if place != "/\(settings.folder)" {
            print("(A folder of yours is called \(settings.folder), so Spaces is numbered. Rename one to change it.)")
        }

        func address(_ uri: String) -> String {
            guard let parts = XRPCClient.spaceParts(uri) else { return uri }
            return "at://\(read.handles[parts.authority] ?? parts.authority)/space/\(parts.type)/\(parts.key)"
        }
        let spaces = read.spaces.values.map { space -> (path: String, space: SpaceData.Space) in
            let node = tree.nodes[NodeID.join(SpacesFolder.id, "s|\(space.uri)")]
            return (node.map { tree.path(of: $0).description } ?? space.uri, space)
        }
        print()
        if spaces.isEmpty {
            print("No spaces yet but ATDrive's own. Include one shared with you in config.toml (spaces.include).")
        }
        for (path, space) in spaces.sorted(by: { $0.path < $1.path }) {
            var notes: [String] = []
            if space.included { notes.append("included") }
            if let problem = space.problem { notes.append("can't read: \(problem)") }
            print(notes.isEmpty ? path : "\(path)  (\(notes.joined(separator: "; ")))")
            print("  \(address(space.uri))")
        }
        if !read.excluded.isEmpty {
            print("\nExcluded (spaces.exclude):")
            for uri in read.excluded.sorted() { print("  \(address(uri))") }
        }
        if !read.unusable.isEmpty {
            print()
            for (address, why) in read.unusable.sorted(by: { $0.key < $1.key }) {
                Output.warn("config.toml's \(address) isn't used: \(why)")
            }
        }
    }
}
