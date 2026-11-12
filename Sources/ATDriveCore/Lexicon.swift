/// The NSIDs ATDrive defines (see `lexicons/`) and the atproto ones it relies on.
public enum Lexicon {
    /// Space type of a drive. One drive = one space.
    public static let driveSpace = "me.jsnelgro.atdrive.drive"
    /// Record collection holding one record per file or folder.
    public static let node = "me.jsnelgro.atdrive.node"
    /// Record collection holding the drive key, wrapped for each passkey that can unlock it.
    public static let key = "me.jsnelgro.atdrive.key"
    /// Space key of the default drive.
    public static let defaultDriveKey = "default"

    /// Policy for a space only its owner can read or write.
    static let personalSpacePolicy = "com.atproto.personalspace.policy"
}
