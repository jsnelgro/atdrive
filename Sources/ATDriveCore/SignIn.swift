import Foundation

/// Signing in, start to finish: the account's own sign-in page (OAuth), then the passkey that
/// unlocks the drive (`DriveUnlock`). On a desktop it's one trip to the browser: once the PDS
/// sends the browser back here, it's sent straight on to the unlock page, and from there back
/// here again.
///
/// When the browser is on another device (signing in on a server over SSH), its redirects to
/// 127.0.0.1 can't reach this machine; the page fails to load, but its address holds the
/// answer, and the user pastes it (`paste`). Each address is useless to anyone else: the sign-in
/// code needs this process's PKCE verifier and DPoP key, and the unlock result is sealed to a
/// key only this process has.
public enum SignIn {
    public enum Step: Sendable, Hashable {
        /// The account's sign-in page, on its PDS.
        case signIn
        /// The unlock page. `alreadyOpen`: the browser was sent there from the sign-in page, so
        /// there's nothing to open; just tell the user to use their passkey there.
        case unlock(alreadyOpen: Bool)
    }

    /// Signs in and unlocks the drive. The session it returns has the drive key.
    ///
    /// `open` shows a URL in the browser. `paste`, if given, reads an address the user copied
    /// out of a browser on another device, for a step; it may be called for both steps.
    public static func run(
        identifier: String, resolver: IdentityResolver = IdentityResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 600,
        open: @escaping @Sendable (URL, Step) async throws -> Void,
        paste: (@Sendable (Step) async throws -> String)? = nil
    ) async throws -> Session {
        let listener = try LoopbackServer()
        let pending = try await OAuthLogin.prepare(
            identifier: identifier, redirectURI: "http://127.0.0.1:\(listener.port)/", resolver: resolver,
            environment: environment, transport: transport)
        try await open(pending.authorizationURL, .signIn)
        var pastedSignIn: (@Sendable () async throws -> [String: String])?
        if let paste {
            pastedSignIn = { try OAuthLogin.redirectParameters(fromPasted: try await paste(.signIn)) }
        }
        let signedIn = try await wait(for: "/", on: listener, timeout: timeout, paste: pastedSignIn)
        let session: Session
        do {
            session = try await pending.complete(with: signedIn.params, transport: transport)
        } catch {
            signedIn.browser?.respond("Sign-in didn't complete. Go back to ATDrive and try again.")
            throw error
        }
        return try await unlock(
            session, listener: listener, browser: signedIn.browser, environment: environment, transport: transport,
            timeout: timeout, open: open, paste: signedIn.browser == nil ? paste : nil)
    }

    /// Unlocks the drive for a session that signed in another way (an app password).
    public static func unlock(
        _ session: Session, environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 600,
        open: @escaping @Sendable (URL, Step) async throws -> Void,
        paste: (@Sendable (Step) async throws -> String)? = nil
    ) async throws -> Session {
        try await unlock(
            session, listener: try LoopbackServer(), browser: nil, environment: environment, transport: transport,
            timeout: timeout, open: open, paste: paste)
    }

    /// `browser`: the sign-in page's redirect, still unanswered, to send on to the unlock page.
    private static func unlock(
        _ session: Session, listener: LoopbackServer, browser: LoopbackRequest?, environment: [String: String],
        transport: any HTTPTransport, timeout: TimeInterval,
        open: @escaping @Sendable (URL, Step) async throws -> Void,
        paste: (@Sendable (Step) async throws -> String)?
    ) async throws -> Session {
        let manager = SessionManager(session, transport: transport)
        let client = XRPCClient(service: session.service, session: manager, transport: transport)
        let unlock: DriveUnlock
        do {
            unlock = try await DriveUnlock.prepare(client: client, owner: session.did)
        } catch {
            browser?.respond("Couldn't open your drive: \(error)")
            throw error
        }
        let request = PasskeyRequest()
        let page = request.pageURL(
            page: DriveUnlock.page(environment: environment), unlock: unlock, did: session.did,
            handle: session.handle, returnTo: URL(string: "http://127.0.0.1:\(listener.port)/unlocked")!)
        if let browser {
            browser.redirect(to: page)
            try await open(page, .unlock(alreadyOpen: true))
        } else {
            try await open(page, .unlock(alreadyOpen: false))
        }
        var pastedAnswer: (@Sendable () async throws -> [String: String])?
        if let paste {
            pastedAnswer = {
                let text = try await paste(.unlock(alreadyOpen: false))
                guard let params = PasskeyRequest.answer(fromPasted: text) else {
                    throw ATDriveError.loginFailed("that isn't the address from the browser")
                }
                return params
            }
        }
        let answer = try await wait(for: "/unlocked", on: listener, timeout: timeout, paste: pastedAnswer)
        do {
            let driveKey = try await unlock.finish(with: try request.result(from: answer.params))
            answer.browser?.respond("Your drive is unlocked. You can close this tab.")
            var unlocked = await manager.session
            unlocked.driveKey = driveKey.rawValue
            return unlocked
        } catch {
            answer.browser?.respond("Couldn't unlock your drive: \(error)")
            throw error
        }
    }

    private struct Arrival: Sendable {
        var params: [String: String]
        /// The browser's request, if it came that way (not pasted), waiting for an answer.
        var browser: LoopbackRequest?
    }

    /// Waits for the browser to come back to `path`, or for the user to paste its address.
    private static func wait(
        for path: String, on listener: LoopbackServer, timeout: TimeInterval,
        paste: (@Sendable () async throws -> [String: String])?
    ) async throws -> Arrival {
        let fromBrowser: @Sendable () async throws -> Arrival = {
            let request = try await listener.nextRequest(path: path, timeout: timeout)
            return Arrival(params: request.params, browser: request)
        }
        guard let paste else { return try await fromBrowser() }
        return try await Race<Arrival>().first(
            fromBrowser, orUnlessItFails: { Arrival(params: try await paste(), browser: nil) })
    }
}
