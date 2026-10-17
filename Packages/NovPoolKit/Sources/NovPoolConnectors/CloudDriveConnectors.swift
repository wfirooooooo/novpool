import Foundation
import NovPoolCore
import NovPoolStorage

/// 文件扩展名 → MIME 类型（上传时必填，给错会导致云端预览异常）。
public enum MimeType {
    public static func forExtension(_ raw: String) -> String {
        switch raw.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "tiff": "image/tiff"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "md": "text/markdown"
        case "txt": "text/plain"
        case "html": "text/html"
        case "json": "application/json"
        case "zip": "application/zip"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: "application/octet-stream"
        }
    }
}

/// 上传用的载荷：文件名 + 字节 + MIME。
struct UploadPayload {
    let fileName: String
    let data: Data
    let mimeType: String

    /// 有原始文件就用原文件；否则把正文落成一份 Markdown 归档。
    static func make(
        payload: NormalizedPayload,
        namingTemplate: String,
        fileManager: FileManager
    ) throws -> UploadPayload {
        if let stagedURL = payload.localStagedURL,
           fileManager.fileExists(atPath: stagedURL.path(percentEncoded: false)),
           let data = try? Data(contentsOf: stagedURL) {
            let template = NamingTemplate(template: namingTemplate)
            let rendered = template.render(
                payload: payload,
                fileExtension: stagedURL.pathExtension.isEmpty ? "dat" : stagedURL.pathExtension
            )
            let fileName = rendered.split(separator: "/").last.map(String.init) ?? stagedURL.lastPathComponent
            return UploadPayload(
                fileName: fileName,
                data: data,
                mimeType: MimeType.forExtension((fileName as NSString).pathExtension)
            )
        }

        let template = NamingTemplate(template: namingTemplate)
        let rendered = template.render(payload: payload, fileExtension: "md")
        let fileName = rendered.split(separator: "/").last.map(String.init) ?? "\(payload.title).md"
        return UploadPayload(
            fileName: fileName,
            data: Data(LocalCloudMountConnector.markdownDocument(for: payload).utf8),
            mimeType: "text/markdown"
        )
    }
}

// MARK: - Google Drive

/// Google Drive 连接器（REST v3）。
///
/// 小文件走 `multipart/related` 一次性上传；大文件走 resumable 上传，
/// 两条路径都直接返回 `webViewLink` 作为云端回执。
public struct GoogleDriveAPIConnector: DestinationConnector, @unchecked Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var namingTemplate: String
        /// 目标文件夹的 Drive ID（Drive API 用 ID 而不是路径）。
        public var folderID: String?

        public init(namingTemplate: String = NamingTemplate.defaultTemplate, folderID: String? = nil) {
            self.namingTemplate = namingTemplate
            self.folderID = folderID
        }

        /// 容错解析：用户（或设置面板）只写关心的字段时，其余走默认值，
        /// 不能因为缺一个键就让整份配置失效。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            namingTemplate = try container.decodeIfPresent(String.self, forKey: .namingTemplate)
                ?? NamingTemplate.defaultTemplate
            folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        }
    }

    /// 超过该体积改用 resumable 上传。
    public static let multipartLimit = 5 * 1024 * 1024

    public var connectorType: String { "gdrive_api" }

    private let credentials: OAuthCredentials?
    private let transport: any HTTPTransport
    private let fileManager: FileManager
    private let tokenService: OAuthTokenService

    public init(
        credentials: OAuthCredentials?,
        transport: any HTTPTransport = URLSessionTransport(),
        fileManager: FileManager = .default
    ) {
        self.credentials = credentials
        self.transport = transport
        self.fileManager = fileManager
        self.tokenService = OAuthTokenService(transport: transport)
    }

    public func validateAuthentication(configJSON: Data) async throws -> Bool {
        guard let credentials, !credentials.refreshToken.isEmpty else { return false }
        _ = try await tokenService.accessToken(credentials: credentials)
        return true
    }

    public func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt {
        let config = (try? JSONDecoder().decode(Config.self, from: configJSON)) ?? Config()
        guard let credentials else {
            throw NovPoolError.authenticationRequired("gdrive_api：请先在设置里完成 Google 授权")
        }
        let accessToken = try await tokenService.accessToken(credentials: credentials)
        let upload = try UploadPayload.make(
            payload: payload,
            namingTemplate: config.namingTemplate,
            fileManager: fileManager
        )

        let metadata: [String: Any] = {
            var value: [String: Any] = ["name": upload.fileName]
            if let folderID = config.folderID, !folderID.isEmpty {
                value["parents"] = [folderID]
            }
            return value
        }()

        let json: [String: Any]
        if upload.data.count <= Self.multipartLimit {
            json = try await multipartUpload(upload, metadata: metadata, accessToken: accessToken)
        } else {
            json = try await resumableUpload(upload, metadata: metadata, accessToken: accessToken)
        }

        guard let fileID = json["id"] as? String else {
            throw NovPoolError.connectorNotConfigured("Google Drive 未返回文件 ID")
        }
        let webURL = (json["webViewLink"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://drive.google.com/file/d/\(fileID)/view")!
        return RemoteReceipt(connectorID: connectorType, remoteItemID: fileID, remoteWebURL: webURL)
    }

    // MARK: - 上传路径

    private func multipartUpload(
        _ upload: UploadPayload,
        metadata: [String: Any],
        accessToken: String
    ) async throws -> [String: Any] {
        let boundary = "novpool-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(upload.mimeType)\r\n\r\n".utf8))
        body.append(upload.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink"
        )!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response = try await transport.send(request)
        try Self.ensureSuccess(response, label: "Google Drive 上传")
        return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    private func resumableUpload(
        _ upload: UploadPayload,
        metadata: [String: Any],
        accessToken: String
    ) async throws -> [String: Any] {
        var start = URLRequest(url: URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink"
        )!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue(upload.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(upload.data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let sessionResponse = try await transport.send(start)
        try Self.ensureSuccess(sessionResponse, label: "Google Drive 建立上传会话")
        guard let locationHeader = sessionResponse.headers
            .first(where: { $0.key.lowercased() == "location" })?.value,
            let location = URL(string: locationHeader) else {
            throw NovPoolError.connectorNotConfigured("Google Drive 未返回上传会话地址")
        }

        var uploadRequest = URLRequest(url: location)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = upload.data
        let response = try await transport.send(uploadRequest)
        try Self.ensureSuccess(response, label: "Google Drive 分片上传")
        return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    static func ensureSuccess(_ payload: HTTPPayload, label: String) throws {
        guard (200..<300).contains(payload.statusCode) else {
            let detail = String(decoding: payload.body.prefix(200), as: UTF8.self)
            throw NovPoolError.connectorNotConfigured("\(label)失败（HTTP \(payload.statusCode)）：\(detail)")
        }
    }
}

// MARK: - OneDrive

/// OneDrive 连接器（Microsoft Graph）。
///
/// 小于 4MB 直接 `PUT .../content`；更大的文件走 `createUploadSession` 分片上传
/// （每片必须是 320KiB 的整数倍，这是 Graph 的硬性要求）。
public struct OneDriveAPIConnector: DestinationConnector, @unchecked Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var namingTemplate: String
        /// 目标路径，例如 `NovPool/技术`；为空表示根目录。
        public var folderPath: String?

        public init(namingTemplate: String = NamingTemplate.defaultTemplate, folderPath: String? = nil) {
            self.namingTemplate = namingTemplate
            self.folderPath = folderPath
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            namingTemplate = try container.decodeIfPresent(String.self, forKey: .namingTemplate)
                ?? NamingTemplate.defaultTemplate
            folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        }
    }

    public static let simpleUploadLimit = 4 * 1024 * 1024
    /// Graph 要求分片大小是 320KiB 的整数倍。
    public static let chunkSize = 5 * 1024 * 1024
    static let uploadChunkUnit = 320 * 1024

    public var connectorType: String { "onedrive_api" }

    private let credentials: OAuthCredentials?
    private let transport: any HTTPTransport
    private let fileManager: FileManager
    private let tokenService: OAuthTokenService

    public init(
        credentials: OAuthCredentials?,
        transport: any HTTPTransport = URLSessionTransport(),
        fileManager: FileManager = .default
    ) {
        self.credentials = credentials
        self.transport = transport
        self.fileManager = fileManager
        self.tokenService = OAuthTokenService(transport: transport)
    }

    public func validateAuthentication(configJSON: Data) async throws -> Bool {
        guard let credentials, !credentials.refreshToken.isEmpty else { return false }
        _ = try await tokenService.accessToken(credentials: credentials)
        return true
    }

    public func push(payload: NormalizedPayload, configJSON: Data) async throws -> RemoteReceipt {
        let config = (try? JSONDecoder().decode(Config.self, from: configJSON)) ?? Config()
        guard let credentials else {
            throw NovPoolError.authenticationRequired("onedrive_api：请先在设置里完成 Microsoft 授权")
        }
        let accessToken = try await tokenService.accessToken(credentials: credentials)
        let upload = try UploadPayload.make(
            payload: payload,
            namingTemplate: config.namingTemplate,
            fileManager: fileManager
        )
        let remotePath = Self.remotePath(folderPath: config.folderPath, fileName: upload.fileName)

        let json: [String: Any]
        if upload.data.count <= Self.simpleUploadLimit {
            json = try await simpleUpload(upload, remotePath: remotePath, accessToken: accessToken)
        } else {
            json = try await chunkedUpload(upload, remotePath: remotePath, accessToken: accessToken)
        }

        guard let itemID = json["id"] as? String else {
            throw NovPoolError.connectorNotConfigured("OneDrive 未返回文件 ID")
        }
        let webURL = (json["webUrl"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://onedrive.live.com/?id=\(itemID)")!
        return RemoteReceipt(connectorID: connectorType, remoteItemID: itemID, remoteWebURL: webURL)
    }

    /// 拼出 `folder/file` 形式的相对路径，并清洗路径穿越。
    static func remotePath(folderPath: String?, fileName: String) -> String {
        let folder = (folderPath ?? "")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
        return folder.isEmpty ? fileName : "\(folder)/\(fileName)"
    }

    private func simpleUpload(
        _ upload: UploadPayload,
        remotePath: String,
        accessToken: String
    ) async throws -> [String: Any] {
        let encoded = Self.encodePath(remotePath)
        var request = URLRequest(url: URL(string:
            "https://graph.microsoft.com/v1.0/me/drive/root:/\(encoded):/content"
        )!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = upload.data

        let response = try await transport.send(request)
        try GoogleDriveAPIConnector.ensureSuccess(response, label: "OneDrive 上传")
        return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    private func chunkedUpload(
        _ upload: UploadPayload,
        remotePath: String,
        accessToken: String
    ) async throws -> [String: Any] {
        let encoded = Self.encodePath(remotePath)
        var session = URLRequest(url: URL(string:
            "https://graph.microsoft.com/v1.0/me/drive/root:/\(encoded):/createUploadSession"
        )!)
        session.httpMethod = "POST"
        session.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        session.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.httpBody = try JSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "replace", "name": upload.fileName],
        ])

        let sessionResponse = try await transport.send(session)
        try GoogleDriveAPIConnector.ensureSuccess(sessionResponse, label: "OneDrive 建立上传会话")
        guard let uploadURL = ((try? JSONSerialization.jsonObject(with: sessionResponse.body)) as? [String: Any])
            .flatMap({ $0["uploadUrl"] as? String })
            .flatMap(URL.init(string:)) else {
            throw NovPoolError.connectorNotConfigured("OneDrive 未返回上传会话地址")
        }

        let total = upload.data.count
        var offset = 0
        var last: [String: Any] = [:]
        while offset < total {
            let end = min(offset + Self.chunkSize, total) - 1
            let chunk = upload.data.subdata(in: offset..<(end + 1))
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("\(Self.chunkSize)", forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            request.httpBody = chunk

            let response = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                try GoogleDriveAPIConnector.ensureSuccess(response, label: "OneDrive 分片上传")
                break
            }
            if let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] {
                last = object
            }
            offset = end + 1
        }
        return last
    }

    /// Graph 路径参数里的特殊字符需要百分号编码（保留 `/` 作为层级分隔）。
    static func encodePath(_ path: String) -> String {
        // 注意：不能把 "/" 从允许集合里去掉——那会把目录分隔符编码成 %2F，
        // Graph 会把它当成文件名的一部分，于是不再创建目录层级。
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
