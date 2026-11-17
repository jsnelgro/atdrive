import Crypto
import Foundation

// Sharing (PLAN.md, "Sharing"): a shared file or folder is a space of its own, of the drive's
// type, under the `memberspace` policy, mounted in its owner's drive where it was. Members, and
// anyone with its link when that's on, mount the same space in their own drives, read-only.

extension Drive {
    /// Makes a new space for a share (or any drive of the owner's other than the home one): the
    /// drive's type, `policy`, and settings in the given mode. An encrypted one gets a new keyring
    /// (its own first key, so its own chunk IDs and chunker seed). Returns it, ready to write.
    static func createSpace(
        client: XRPCClient, owner: String, key: String, encrypted: Bool, policy: SpacePolicy,
        transfers: TransferOptions = .standard, device: String = DeviceName.current, tids: TIDSource = .system
    ) async throws -> Drive {
        let space = try await client.createSpace(type: Lexicon.driveSpace, key: key, policy: policy)
        let keyring = encrypted ? Keyring(DriveKey()) : nil
        let drive = Drive(
            client: client, owner: owner, space: space, transfers: transfers, device: device, tids: tids,
            mode: encrypted ? .encrypted : .plain, keyring: keyring)
        try await drive.writeSettingsIfMissing(DriveSettings(driveID: DriveSettings.newDriveID()))
        return drive
    }

    /// Writes the settings record, unless there is one (an interrupted share, run again).
    func writeSettingsIfMissing(_ settings: DriveSettings) async throws {
        guard try await settingsRecord() == nil else { return }
        do {
            try await apply([
                .create(
                    collection: Lexicon.settings, rkey: Lexicon.settingsKey, value: try stored(settings, with: keyring))
            ])
        } catch let error as XRPCError where error.error == "RecordAlreadyExists" {}
    }

    /// Writes a mount node: `info`'s space appears as `name` in `parent`.
    @discardableResult
    func createMount(_ info: MountInfo, named name: String, in parent: String?, id: String? = nil) async throws -> Node {
        try DrivePath.validate(name: name)
        var record = NodeRecord(name: name, parent: parent, kind: .mount)
        record.mount = info
        return try await commit(change(.create, node: id ?? tids.next(), record: record, .created, prev: nil))!
    }

    /// Changes what a mount holds (a new keyring, say), keeping its place and name.
    @discardableResult
    func updateMount(_ node: Node, _ info: MountInfo) async throws -> Node {
        var record = node.record
        record.mount = info
        return try await commit(change(.update, node: node.id, record: record, .edited, prev: node.record.version))!
    }
}

/// A random space key for a share: 128 bits in base32 (26 characters). A plain share's public link
/// has only its address to protect it, so the address mustn't be guessable.
public func newShareKey() -> String {
    Base32.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
}
