/// ATDrive's version: the only place it's written down.
///
/// `atdrive --version` prints it, `scripts/build-app.sh` puts it in the app's and the extension's
/// Info.plists, and a release (a `v<version>` tag) fails if the tag doesn't match it. To release,
/// change it here, merge, then tag. See "Releasing" in the README.
public enum ATDriveVersion {
    public static let current = "0.5.0"
}
