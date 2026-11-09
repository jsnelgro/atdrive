import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An error response from an atproto server: `{"error": "Name", "message": "…"}`.
public struct XRPCError: Error, CustomStringConvertible, Sendable {
    public let method: String
    public let status: Int
    public let error: String?
    public let message: String?

    init(method: String, status: Int, body: Data) {
        struct Payload: Decodable {
            var error: String?
            var message: String?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: body)
        self.method = method
        self.status = status
        self.error = payload?.error
        self.message = payload?.message
    }

    public var description: String {
        let detail = [error, message].compactMap { $0 }.joined(separator: ": ")
        return "\(detail.isEmpty ? "request failed" : detail) (HTTP \(status) from \(method))"
    }
}

/// Minimal client for atproto's HTTP API (XRPC): JSON in, JSON out, bearer-token auth with
/// automatic refresh, and polite retries when rate-limited.
public final class XRPCClient: Sendable {
    public let service: URL
    public let session: SessionManager?
    let transport: any HTTPTransport

    public init(
        service: URL, session: SessionManager? = nil,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.service = service
        self.session = session
        self.transport = transport
    }

    enum Auth: Sendable {
        /// Use the session's access token, refreshing it if it has expired.
        case session
        case bearer(String)
        case none
    }

    struct Empty: Codable {}

    // MARK: Typed helpers

    /// GET a query and decode its JSON output.
    public func query<Output: Decodable>(
        _ method: String, _ params: [String: String?] = [:], as _: Output.Type = Output.self
    ) async throws -> Output {
        try decode(await send(method, params: params, auth: .session), from: method)
    }

    /// GET a query whose output is raw bytes (e.g. a blob).
    public func queryBytes(_ method: String, _ params: [String: String?] = [:]) async throws -> Data {
        try await send(method, params: params, auth: .session)
    }

    /// POST a procedure with a JSON body and decode its JSON output.
    public func procedure<Output: Decodable>(
        _ method: String, _ input: some Encodable, as _: Output.Type = Output.self
    ) async throws -> Output {
        try decode(
            await send(method, body: (try Self.encoder.encode(input), "application/json"), auth: .session),
            from: method)
    }

    /// POST raw bytes (e.g. uploadBlob) and decode the JSON output.
    public func procedure<Output: Decodable>(
        _ method: String, bytes: Data, contentType: String, as _: Output.Type = Output.self
    ) async throws -> Output {
        try decode(await send(method, body: (bytes, contentType), auth: .session), from: method)
    }

    // MARK: Transport

    func send(
        _ method: String, params: [String: String?] = [:], body: (Data, String)? = nil,
        auth: Auth
    ) async throws -> Data {
        var components = URLComponents(
            url: service.appendingPathComponent("xrpc/\(method)"), resolvingAgainstBaseURL: false)!
        let items = params.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        let isQuery = body == nil
        var refreshed = false
        var retriedNonce = false
        var attempt = 0

        while true {
            attempt += 1
            var request = URLRequest(url: components.url!)
            request.httpMethod = isQuery ? "GET" : "POST"
            if let (data, contentType) = body {
                request.httpBody = data
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            var token: String?
            switch auth {
            case .session:
                if let session {
                    let authorization = try await session.authorization(
                        method: request.httpMethod ?? "GET", url: request.url!)
                    for (name, value) in authorization.headers { request.setValue(value, forHTTPHeaderField: name) }
                    token = authorization.token
                }
            case .bearer(let value):
                request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            case .none: break
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                // Network hiccup: safe to retry reads; writes are left to the caller.
                guard isQuery, attempt < 4 else { throw error }
                try await Task.sleep(nanoseconds: Self.backoff(attempt))
                continue
            }
            let newNonce = await session?.observe(response, for: request.url!) ?? false
            if (200..<300).contains(response.statusCode) { return data }

            let error = XRPCError(method: method, status: response.statusCode, body: data)
            let challenge = response.header("WWW-Authenticate") ?? ""
            if case .session = auth, let session, let token {
                // OAuth: the PDS wants the proof signed with a fresh nonce it just sent.
                if response.statusCode == 401, challenge.contains("use_dpop_nonce") || error.error == "use_dpop_nonce",
                    newNonce, !retriedNonce
                {
                    retriedNonce = true
                    continue
                }
                let expired =
                    error.error == "ExpiredToken"
                    || (response.statusCode == 401
                        && (["invalid_token", "InvalidToken"].contains(error.error ?? "")
                            || challenge.contains("invalid_token")))
                if expired, !refreshed {
                    try await session.refresh(expiredAccessToken: token)
                    refreshed = true
                    continue
                }
            }
            if response.statusCode == 429, attempt < 6 {
                try await Task.sleep(nanoseconds: Self.rateLimitDelay(response, attempt: attempt))
                continue
            }
            if response.statusCode >= 500, isQuery, attempt < 4 {
                try await Task.sleep(nanoseconds: Self.backoff(attempt))
                continue
            }
            throw error
        }
    }

    private func decode<Output: Decodable>(_ data: Data, from method: String) throws -> Output {
        if Output.self == Empty.self, data.isEmpty { return Empty() as! Output }
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw ATDriveError.unexpectedResponse("\(method): \(error)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private static func backoff(_ attempt: Int) -> UInt64 {
        UInt64(min(pow(2.0, Double(attempt)), 30) * 1_000_000_000) / 4
    }

    /// Waits until the server's `ratelimit-reset` (unix seconds) when given, capped at a minute.
    private static func rateLimitDelay(_ response: HTTPURLResponse, attempt: Int) -> UInt64 {
        if let reset = response.header("ratelimit-reset").flatMap(Double.init) {
            let seconds = min(max(reset - Date().timeIntervalSince1970, 1), 60)
            return UInt64(seconds * 1_000_000_000)
        }
        return backoff(attempt + 2)
    }
}
