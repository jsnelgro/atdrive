public enum ATDriveError: Error, CustomStringConvertible, Equatable {
    case notLoggedIn
    /// The server won't renew the session: it expired, or it was revoked (signed out
    /// elsewhere, or from the account's settings).
    case sessionEnded
    case loginFailed(String)
    case identity(String)
    case notFound(String)
    case alreadyExists(String)
    case notAFolder(String)
    case isAFolder(String)
    case needsRecursive(String)
    case invalidName(String)
    case invalidMove(String)
    case integrity(String)
    case unexpectedResponse(String)
    /// Not a link (or `at://` address) to a space.
    case invalidLink(String)
    /// Inside a folder someone else shared: only they can change it.
    case readOnly(path: String, owner: String)
    /// Inside a shared folder that can't be read right now.
    case mountUnavailable(path: String, why: String)

    public var description: String {
        switch self {
        case .notLoggedIn: "not logged in (run `atdrive login <handle>`)"
        case .sessionEnded: "your session has ended; sign in again (`atdrive login <handle>`)"
        case .loginFailed(let why): "login failed: \(why)"
        case .identity(let why): why
        case .notFound(let path): "\(path): no such file or folder"
        case .alreadyExists(let path): "\(path): already exists"
        case .notAFolder(let path): "\(path): not a folder"
        case .isAFolder(let path): "\(path): is a folder"
        case .needsRecursive(let path): "\(path) is a folder (use -r)"
        case .invalidName(let name): "invalid name: \"\(name)\""
        case .invalidMove(let why): why
        case .integrity(let why): "integrity check failed: \(why)"
        case .unexpectedResponse(let why): "unexpected server response: \(why)"
        case .invalidLink(let text): "not an ATDrive link or space address: \(text)"
        case .readOnly(let path, let owner): "\(path) is read-only: \(owner) shared it with you"
        case .mountUnavailable(let path, let why): "\(path) is in a shared folder that can't be read now: \(why)"
        }
    }
}
