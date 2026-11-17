import Foundation

/// Takes an account back to a clean slate, as if ATDrive had never been used: for trying things
/// out, and for testing by hand.
public enum AccountReset {
    /// What `run` deleted.
    public struct Result: Sendable, Equatable {
        /// Every ATDrive space the account owned: its drive, and the folders it shared.
        public var spaces: [String]
        /// Whether it had published a sharing key.
        public var sharingKey: Bool
    }

    /// Deletes every ATDrive space `owner` owns (its drive, and the folders it shared, so members
    /// and link holders are told they're gone), and the sharing key it published. Nothing of other
    /// people's is touched: their shares just stop being mounted, with the drive.
    public static func run(client: XRPCClient, owner: String) async throws -> Result {
        let spaces = try await client.listSpaces(type: Lexicon.driveSpace).filter {
            XRPCClient.spaceParts($0)?.authority == owner
        }
        for space in spaces { try await client.deleteSpace(space) }
        let published =
            try await client.getPublicRecord(repo: owner, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey)
            != nil
        if published {
            try await client.deletePublicRecord(repo: owner, collection: Lexicon.shareKey, rkey: Lexicon.shareKeyKey)
        }
        return Result(spaces: spaces, sharingKey: published)
    }
}
