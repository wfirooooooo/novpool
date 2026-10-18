import Foundation
import NovPoolCore
import NovPoolStorage

/// File extension → MIME type (required when uploading; entering it incorrectly will cause cloud preview errors).
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

/// Payload for upload: Filename + bytes + MIME.
struct UploadPayload {
    let fileName: String
    let data: Data
    let mimeType: String

    /// Use the original file if it exists; otherwise, save the Body as a Markdown archive.
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

/// Google Drive Connector (REST v3).
///
/// Small files use `multipart/related` for one-time upload; large files use resumable upload,
/// Both paths directly return `webViewLink` as the Remote receipt.
public struct GoogleDriveAPIConnector: DestinationConnector, @unchecked Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var namingTemplate: String
        /// The Drive ID of the target folder (Drive API uses ID instead of path).
        public var folderID: String?

        public init(namingTemplate: String = NamingTemplate.defaultTemplate, folderID: String? = nil) {
            self.namingTemplate = namingTemplate
            self.folderID = folderID
        }

        /// Fault-tolerant parsing: When the user (or settings panel) only writes the fields of concern, the rest use default values.
        /// You can't let the entire configuration fail just because one key is missing.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            namingTemplate = try container.decodeIfPresent(String.self, forKey: .namingTemplate)
                ?? NamingTemplate.defaultTemplate
            folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        }
    }

    /// Use resumable upload for volumes exceeding this size.
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
            throw NovPoolError.authenticationRequired("gdrive_api: complete Google authorization in Settings first")
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
            throw NovPoolError.connectorNotConfigured("Google Drive did not return a file ID")
        }
        let webURL = (json["webViewLink"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://drive.google.com/file/d/\(fileID)/view")!
        return RemoteReceipt(connectorID: connectorType, remoteItemID: fileID, remoteWebURL: webURL)
    }

    // MARK: - Upload paths

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
        try Self.ensureSuccess(response, label: "Google Drive upload")
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
        try Self.ensureSuccess(sessionResponse, label: "Google Drive create upload session")
        guard let locationHeader = sessionResponse.headers
            .first(where: { $0.key.lowercased() == "location" })?.value,
            let location = URL(string: locationHeader) else {
            throw NovPoolError.connectorNotConfigured("Google Drive did not return an upload session URL")
        }

        var uploadRequest = URLRequest(url: location)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = upload.data
        let response = try await transport.send(uploadRequest)
        try Self.ensureSuccess(response, label: "Google Drive chunked upload")
        return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    static func ensureSuccess(_ payload: HTTPPayload, label: String) throws {
        guard (200..<300).contains(payload.statusCode) else {
            let detail = String(decoding: payload.body.prefix(200), as: UTF8.self)
            throw NovPoolError.connectorNotConfigured("\(label) failed (HTTP\(payload.statusCode)): \(detail)")
        }
    }
}

// MARK: - OneDrive

/// OneDrive Connector (Microsoft Graph).
///
/// Files smaller than 4MB can be directly `PUT .../content`; larger files use `createUploadSession` for chunked upload
///  (Each piece must be a multiple of 320 KiB, which is a strict requirement of Graph).
public struct OneDriveAPIConnector: DestinationConnector, @unchecked Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var namingTemplate: String
        /// Target path, for example `NovPool/Technology`; empty means the root directory.
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
    /// Graph requires the shard size to be a multiple of 320 KiB.
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
            throw NovPoolError.authenticationRequired("onedrive_api: complete Microsoft authorization in Settings first")
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
            throw NovPoolError.connectorNotConfigured("OneDrive did not return a file ID")
        }
        let webURL = (json["webUrl"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://onedrive.live.com/?id=\(itemID)")!
        return RemoteReceipt(connectorID: connectorType, remoteItemID: itemID, remoteWebURL: webURL)
    }

    /// Construct a relative path in the form of `folder/file` and sanitize path traversal.
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
        try GoogleDriveAPIConnector.ensureSuccess(response, label: "OneDrive upload")
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
        try GoogleDriveAPIConnector.ensureSuccess(sessionResponse, label: "OneDrive create upload session")
        guard let uploadURL = ((try? JSONSerialization.jsonObject(with: sessionResponse.body)) as? [String: Any])
            .flatMap({ $0["uploadUrl"] as? String })
            .flatMap(URL.init(string:)) else {
            throw NovPoolError.connectorNotConfigured("OneDrive did not return an upload session URL")
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
                try GoogleDriveAPIConnector.ensureSuccess(response, label: "OneDrive chunked upload")
                break
            }
            if let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] {
                last = object
            }
            offset = end + 1
        }
        return last
    }

    /// Special characters in Graph path parameters need to be percent-encoded (keeping `/` as a hierarchy separator).
    static func encodePath(_ path: String) -> String {
        // Note: You cannot remove "/" from the allowed set — that would encode the directory separator as %2F,
        // Graph will treat it as part of the filename, so it will no longer create a directory hierarchy.
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
