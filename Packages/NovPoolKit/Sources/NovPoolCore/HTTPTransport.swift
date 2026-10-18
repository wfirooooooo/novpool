import Foundation

/// HTTP response payload (decoupled from `URLSession`, making it easier to inject substitutes for protocol layer testing).
public struct HTTPPayload: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    /// The final URL after redirection.
    public let finalURL: URL?

    public init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }

    /// Convenient construction: JSON Text response.
    public init(json: String, statusCode: Int = 200) {
        self.init(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }
}

/// HTTP transport abstraction.
///
/// Single network entry point for both web fetch (NovPoolSystemBridge) and cloud connectors (NovPoolConnectors)
/// It all goes through it, so unit tests can fully verify request construction and response parsing offline.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPPayload
}

extension HTTPTransport {
    /// Alias for backward-compatible call points.
    public func get(_ request: URLRequest) async throws -> HTTPPayload {
        try await send(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPPayload {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPPayload(
            statusCode: http?.statusCode ?? 0,
            headers: headers,
            body: data,
            finalURL: response.url
        )
    }
}
