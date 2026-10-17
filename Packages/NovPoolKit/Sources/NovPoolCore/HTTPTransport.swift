import Foundation

/// HTTP 响应载荷（与 `URLSession` 解耦，便于注入替身做协议层测试）。
public struct HTTPPayload: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    /// 经过重定向后的最终 URL。
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

    /// 便捷构造：JSON 文本响应。
    public init(json: String, statusCode: Int = 200) {
        self.init(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }
}

/// HTTP 传输抽象。
///
/// 全项目只有这一个网络出入口：抓网页（NovPoolSystemBridge）与云端连接器（NovPoolConnectors）
/// 都走它，因此单元测试可以完全离线地验证请求构造与响应解析。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPPayload
}

extension HTTPTransport {
    /// 兼容旧调用点的别名。
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
