import Dispatch
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A tiny web server on 127.0.0.1 that catches the browser when the OAuth sign-in page
/// redirects back to the app (`http://127.0.0.1:<port>/?code=…`), and again when the unlock
/// page does (`/unlocked?result=…`; see `DriveUnlock`). Works the same in the
/// CLI on macOS/Linux and in the sandboxed Mac app (which needs the network.server entitlement).
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32

    init() throws {
        #if canImport(Glibc)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ATDriveError.loginFailed("couldn't open a local port for the sign-in redirect") }

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ATDriveError.loginFailed("couldn't listen on 127.0.0.1 for the sign-in redirect")
        }
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        socketFD = fd
    }

    deinit { close(socketFD) }

    /// Waits for the browser's redirect and returns its query parameters, after showing the
    /// user a page saying whether sign-in worked.
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        let request = try await nextRequest(path: "/", timeout: timeout)
        request.respond(
            request.params["error"] == nil
                ? "You're signed in to ATDrive. You can close this tab."
                : "Sign-in didn't complete. Go back to ATDrive and try again.")
        return request.params
    }

    /// Waits for the browser to load `path` with a `state` parameter, and hands over the request
    /// unanswered, so the caller can answer it (or send the browser on) once it's done its work.
    /// Anything else (e.g. `/favicon.ico`) gets a 404.
    func nextRequest(path: String, timeout: TimeInterval) async throws -> LoopbackRequest {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(
                        with: Result {
                            try self.waitForRequest(path: path, until: Date() + timeout, cancelled: cancelled)
                        })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func waitForRequest(path: String, until deadline: Date, cancelled: CancelFlag) throws -> LoopbackRequest {
        while true {
            if cancelled.isSet { throw CancellationError() }
            guard deadline.timeIntervalSinceNow > 0 else {
                throw ATDriveError.loginFailed("timed out waiting for sign-in to finish in the browser")
            }
            // Wake every half second to notice cancellation and the deadline.
            var poller = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 500) > 0 else { continue }
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { continue }

            // "GET /?state=…&code=… HTTP/1.1"
            let requestLine = readRequestHead(client).split(separator: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: String(parts[1])), url.path == path,
                let items = url.queryItems, items.contains(where: { $0.name == "state" })
            else {
                LoopbackRequest.send(client, status: "404 Not Found", headers: [], body: "Not found")
                close(client)
                continue
            }
            let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            return LoopbackRequest(client: client, params: params)
        }
    }

    private func readRequestHead(_ client: Int32) -> String {
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data += buffer[0..<count]
            if String(decoding: data, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

}

/// A request from the browser, waiting for an answer. Answered (and its connection closed)
/// exactly once: if nothing else answers it, the browser gets a generic page.
final class LoopbackRequest: @unchecked Sendable {
    let params: [String: String]
    private let client: Int32
    private let lock = NSLock()
    private var answered = false

    init(client: Int32, params: [String: String]) {
        self.client = client
        self.params = params
    }

    deinit { respond("Go back to ATDrive.") }

    /// Shows a page with a message.
    func respond(_ message: String) {
        answer(status: "200 OK", headers: ["Content-Type: text/html; charset=utf-8"], body: Self.page(message))
    }

    /// Sends the browser somewhere else.
    func redirect(to url: URL) {
        answer(
            status: "303 See Other",
            headers: ["Location: \(url.absoluteString)", "Referrer-Policy: no-referrer", "Cache-Control: no-store"],
            body: "")
    }

    private func answer(status: String, headers: [String], body: String) {
        guard
            lock.withLock({ () -> Bool in
                defer { answered = true }
                return !answered
            })
        else { return }
        Self.send(client, status: status, headers: headers, body: body)
        close(client)
    }

    static func send(_ client: Int32, status: String, headers: [String], body: String) {
        let head = (["HTTP/1.1 \(status)"] + headers + ["Content-Length: \(body.utf8.count)", "Connection: close"])
            .joined(separator: "\r\n")
        let response = Array((head + "\r\n\r\n" + body).utf8)
        // Don't let a browser that hangs up early kill the process with SIGPIPE.
        #if canImport(Glibc)
            _ = response.withUnsafeBytes { Glibc.send(client, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        #else
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        #endif
    }

    private static func page(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>ATDrive</title>
            <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;\
            height:90vh;margin:0;color:#222}@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}}</style>
            </head><body><p>\(escaped)</p></body></html>
            """
    }
}

/// Set once, read from any thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
