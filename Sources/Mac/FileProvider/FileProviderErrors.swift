import ATDriveCore
import FileProvider
import Foundation

/// Translates ATDrive and network errors into the File Provider errors Finder understands
/// (e.g. "not signed in" shows a sign-in prompt instead of a generic failure).
enum FileProviderErrors {
    static func map(_ error: Error) -> Error {
        switch error {
        case is NSFileProviderError, is CocoaError:
            return error
        case let error as ATDriveError:
            switch error {
            case .notLoggedIn, .sessionEnded, .loginFailed: return NSFileProviderError(.notAuthenticated)
            case .notFound: return NSFileProviderError(.noSuchItem)
            case .alreadyExists: return NSFileProviderError(.filenameCollision)
            case .invalidName: return CocoaError(.fileWriteInvalidFileName)
            default: return describe(error)
            }
        case let error as XRPCError:
            let authErrors = ["AuthMissing", "AuthenticationRequired", "InvalidToken", "ExpiredToken"]
            if error.status == 401 || authErrors.contains(error.error ?? "") {
                return NSFileProviderError(.notAuthenticated)
            }
            if error.status == 429 || error.status >= 500 { return NSFileProviderError(.serverUnreachable) }
            return describe(error)
        case is URLError:
            return NSFileProviderError(.serverUnreachable)
        default:
            return error
        }
    }

    private static func describe(_ error: CustomStringConvertible) -> Error {
        NSError(
            domain: "me.jsnelgro.atdrive", code: 1,
            userInfo: [NSLocalizedDescriptionKey: error.description])
    }
}
