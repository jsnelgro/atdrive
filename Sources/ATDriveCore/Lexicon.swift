/// The NSIDs ATDrive defines (see `lexicons/`) and the atproto ones it relies on.
public enum Lexicon {
    /// Space type of a drive. One drive = one space.
    public static let driveSpace = "app.atdrive.drive"
    /// Record collection holding one record per file or folder.
    public static let node = "app.atdrive.node"
    /// Record collection holding one record per change to a file or folder: the history.
    public static let version = "app.atdrive.version"
    /// Record collection holding the drive's settings, in one record (`settingsKey`).
    public static let settings = "app.atdrive.settings"
    /// Record key of the drive's settings record.
    public static let settingsKey = "self"
    /// Record collection holding one record per device (keyed by its ID), with the drive's
    /// keyring wrapped for it, plus the keyring wrapped with the recovery key (`recoveryKey`).
    public static let device = "app.atdrive.device"
    /// Record key of the keyring wrapped with the recovery key, in `device`.
    public static let recoveryKey = "recovery"
    /// Record collection holding the rest of chunk lists too long for the version record that
    /// holds them, in order (`continuationKey`).
    public static let chunks = "app.atdrive.chunks"
    /// Record collection, in an account's public repo, holding its sharing key (`shareKeyKey`):
    /// what encrypted shares are wrapped for.
    public static let shareKey = "app.atdrive.shareKey"
    /// Record key of the sharing key.
    public static let shareKeyKey = "self"
    /// Record collection, in a shared space, holding one record per member (keyed by their DID)
    /// of an encrypted share: its keyring wrapped for them (`MemberRecord`).
    public static let member = "app.atdrive.member"
    /// Record collection, in a shared space, holding its link record (`linkKey`): an encrypted
    /// share's keyring sealed with its public link's key (`ShareLink`).
    public static let link = "app.atdrive.link"
    /// Record key of the link record.
    public static let linkKey = "self"
    /// Record collection, in the home drive, holding one record per person (keyed by their DID)
    /// whose sharing key was verified with a code (`VerifiedKey`).
    public static let contact = "app.atdrive.contact"
    /// Record collection, in the home drive, holding one record per share this account declined
    /// (`DeclinedShare`, keyed by `DeclinedShare.key(for:)`): it isn't pending any more.
    public static let declined = "app.atdrive.declined"
    /// Space key of the default drive.
    public static let defaultDriveKey = "default"
    /// Space type of an account's inbox: where people who share with it leave invites (#68).
    public static let inboxSpace = "app.atdrive.inbox"
    /// Space key of the inbox (each account has one).
    public static let inboxKey = "self"
    /// Record collection, in a sender's repo in someone's inbox, holding one record per share
    /// waiting for them (`InviteRecord`), keyed by the share's space key.
    public static let invite = "app.atdrive.invite"

    /// Record key of a version's `index`th `chunks` record (from 1): the version's own key, a
    /// dash, and the number.
    public static func continuationKey(of version: String, _ index: Int) -> String { "\(version)-\(index)" }

    /// The version a `chunks` record belongs to, and which of its records it is; `nil` for a key
    /// `continuationKey` doesn't make.
    public static func continuationOwner(_ key: String) -> (version: String, index: Int)? {
        guard let dash = key.lastIndex(of: "-"), let index = Int(key[key.index(after: dash)...]), index > 0 else {
            return nil
        }
        return (String(key[..<dash]), index)
    }

    /// Policy for a space only its owner can read or write.
    static let personalSpacePolicy = "com.atproto.personalspace.policy"
    /// Policy for a space its owner shares with members (and, with `publicRead`, anyone).
    static let memberSpacePolicy = "com.atproto.memberspace.policy"
}
