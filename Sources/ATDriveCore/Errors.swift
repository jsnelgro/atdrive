public enum ATDriveError: Error, CustomStringConvertible, Equatable {
    case notLoggedIn
    /// The server won't renew the session: it expired, or it was revoked (e.g. its app password
    /// was deleted).
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
        }
    }
}
