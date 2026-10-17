import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import NovPoolUI

/// 设置中心的读写入口。
///
/// 所有可调项都落在 `UserDefaults`（键名与 `NovPoolSettings` 一致），
/// 连接器则落在数据库（凭据在 Keychain）。设置面板只经过这一个类型，便于测试与审计。
@MainActor
@Observable
final class AppSettingsStore {
    struct LocalMountDraft {
        var id: String
        var name: String
        var bookmark: Data
        var namingTemplate: String
    }

    private let defaults: UserDefaults
    private let connectorRepository: ConnectorRepository
    private let keychain: KeychainStore
    private let database: NovPoolDatabase

    var searchHotKey: String
    var isAIEnabled: Bool
    var categoriesText: String
    var chatModel: String
    var embeddingModel: String
    var ollamaBaseURL: String
    var openAIBaseURL: String
    var openAIAPIKey: String
    var isSyncEnabled: Bool
    var routeRulesJSON: String
    var defaultConnectorIDsText: String

    private(set) var connectors: [ConnectorRecord] = []
    private(set) var queueCounts: [String: Int] = [:]
    private(set) var statusMessage: String?
    private(set) var statusIsError = false

    // 云端连接器表单草稿
    var notionToken = ""
    var notionDatabaseID = ""
    var notionTitleProperty = "Name"
    var notionUrlProperty = ""
    var notionTagsProperty = ""
    var notionCategoryProperty = ""
    var notionSummaryProperty = ""
    private(set) var notionDatabases: [NotionDatabase] = []
    private(set) var isFetchingNotionDatabases = false

    var driveClientID = ""
    var driveFolderID = ""

    var oneDriveClientID = ""
    var oneDriveTenant = "common"
    var oneDriveFolderPath = "NovPool"

    var notionClientID = ""
    var notionClientSecret = ""
    private(set) var isAuthorizing = false
    /// 浏览器授权编排（会话由 NovPoolUI 提供，走系统组件复用浏览器登录态）。
    private let authorizer: ConnectorAuthorizationCoordinator

    /// 扇区槽位草稿（最多四个）。
    var zoneDrafts: [DropZone] = []
    /// 本机 llama.cpp 服务。
    let localLLM = LocalLLMServerManager()
    var prefersLocalLLM: Bool
    /// 由 AppEnvironment 注入：批量重新总结尚无摘要的条目。
    var resummarizeMissingHandler: (@MainActor () async -> String)?
    private(set) var isResummarizing = false

    init(
        defaults: UserDefaults = .standard,
        connectorRepository: ConnectorRepository,
        database: NovPoolDatabase,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.connectorRepository = connectorRepository
        self.database = database
        self.keychain = keychain

        let settings = NovPoolSettings.load(defaults)
        searchHotKey = defaults.string(forKey: "novpool.hotkey") ?? "cmd+shift+space"
        isAIEnabled = settings.isAIEnabled
        categoriesText = settings.categories.joined(separator: "、")
        chatModel = settings.chatModel
        embeddingModel = settings.embeddingModel
        ollamaBaseURL = settings.ollamaBaseURL.absoluteString
        openAIBaseURL = settings.openAIBaseURL?.absoluteString ?? ""
        openAIAPIKey = settings.openAIAPIKey ?? ""
        isSyncEnabled = settings.isSyncEnabled
        routeRulesJSON = settings.routeRulesJSON
        defaultConnectorIDsText = settings.defaultConnectorIDs.joined(separator: ",")
        zoneDrafts = DropZoneConfiguration.zones(from: defaults.string(forKey: DropZoneConfiguration.defaultsKey))
        prefersLocalLLM = defaults.bool(forKey: "novpool.llama.enabled")
        authorizer = ConnectorAuthorizationCoordinator(
            session: WebBrowserAuthorizationSession(logger: { NovPoolLog.write($0) }),
            credentials: keychain,
            connectorRepository: connectorRepository
        )
    }

    // MARK: - 加载 / 保存

    func reloadConnectors() async {
        connectors = (try? await connectorRepository.list()) ?? []
    }

    func reloadQueue() async {
        let repository = OutboxRepository(database: database)
        let counts = (try? await repository.statusCounts()) ?? [:]
        queueCounts = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    func save() {
        defaults.set(searchHotKey, forKey: "novpool.hotkey")
        defaults.set(isAIEnabled, forKey: "novpool.ai.enabled")
        defaults.set(parseCategories(categoriesText), forKey: "novpool.ai.categories")
        defaults.set(chatModel, forKey: "novpool.ai.chatModel")
        defaults.set(embeddingModel, forKey: "novpool.ai.embeddingModel")
        defaults.set(ollamaBaseURL, forKey: "novpool.ollama.baseURL")
        if openAIBaseURL.isEmpty {
            defaults.removeObject(forKey: "novpool.openai.baseURL")
        } else {
            defaults.set(openAIBaseURL, forKey: "novpool.openai.baseURL")
        }
        if openAIAPIKey.isEmpty {
            defaults.removeObject(forKey: "novpool.openai.apiKey")
        } else {
            defaults.set(openAIAPIKey, forKey: "novpool.openai.apiKey")
        }
        defaults.set(isSyncEnabled, forKey: "novpool.sync.enabled")
        defaults.set(routeRulesJSON, forKey: "novpool.routes")
        defaults.set(
            defaultConnectorIDsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            forKey: "novpool.connectors.default"
        )
        showStatus("已保存（快捷键、路由与连接器变更需要重启 NovPool 生效）")
    }

    func validateRouteRules() {
        guard !routeRulesJSON.isEmpty else {
            showStatus("路由规则为空：所有条目都会走默认连接器")
            return
        }
        guard let data = routeRulesJSON.data(using: .utf8) else {
            showStatus("路由规则不是有效文本", isError: true)
            return
        }
        do {
            let rules = try JSONDecoder().decode([RouteRule].self, from: data)
            showStatus("路由规则可用，共 \(rules.count) 条")
        } catch {
            showStatus("路由规则解析失败：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - 连接器

    /// 添加本地云盘挂载目录（Google Drive / OneDrive / iCloud / Obsidian 库）。
    /// 用安全作用域书签持久化访问权限，因此重启后依然可写。
    func addLocalMountConnector(id: String, name: String, directory: URL, namingTemplate: String) async {
        do {
            let bookmark = try SecurityScopedBookmark.make(for: directory)
            let config = try JSONSerialization.data(withJSONObject: [
                "namingTemplate": namingTemplate,
                "rootPath": directory.path(percentEncoded: false),
            ])
            try await connectorRepository.upsert(ConnectorRecord(
                id: id,
                name: name,
                connectorType: "local_mount",
                bookmarkData: bookmark,
                configJSON: String(decoding: config, as: UTF8.self)
            ))
            await reloadConnectors()
            showStatus("已添加归档目录：\(directory.lastPathComponent)")
        } catch {
            showStatus("添加失败：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - 云端连接器

    /// 用当前 Token 拉取 Notion 数据库列表，供下拉选择（需要联网与有效 Token）。
    func fetchNotionDatabases() async {
        isFetchingNotionDatabases = true
        defer { isFetchingNotionDatabases = false }
        let connector = NotionConnector(token: notionToken.isEmpty ? nil : notionToken)
        do {
            let config = NotionConnector.Config(databaseID: notionDatabaseID, titleProperty: notionTitleProperty)
            notionDatabases = try await connector.listDatabases(
                configJSON: try JSONEncoder().encode(config)
            )
            if notionDatabases.isEmpty {
                showStatus("该授权下没有可写入的数据库：请先把集成添加进目标数据库", isError: true)
            } else {
                showStatus("拉到 \(notionDatabases.count) 个数据库")
            }
        } catch {
            showStatus("拉取数据库失败：\(error.localizedDescription)", isError: true)
        }
    }

    func saveNotionConnector() async {
        guard !notionToken.isEmpty else {
            showStatus("请先填写 Notion Integration Token（ntn_ 开头）", isError: true)
            return
        }
        guard !notionDatabaseID.isEmpty else {
            showStatus("请填写或选择目标数据库 ID", isError: true)
            return
        }
        let config = NotionConnector.Config(
            databaseID: notionDatabaseID,
            titleProperty: notionTitleProperty.isEmpty ? "Name" : notionTitleProperty,
            urlProperty: notionUrlProperty.nilIfBlank,
            tagsProperty: notionTagsProperty.nilIfBlank,
            categoryProperty: notionCategoryProperty.nilIfBlank,
            summaryProperty: notionSummaryProperty.nilIfBlank
        )
        do {
            let configJSON = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            await upsertRemoteConnector(
                id: "notion",
                name: "Notion",
                type: "notion",
                configJSON: configJSON,
                token: notionToken
            )
        } catch {
            showStatus("配置序列化失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// 浏览器授权（Google Drive）：用户只点按钮 + 登录，令牌自动写入钥匙串。
    func authorizeGoogleDrive() async {
        await runAuthorization(label: "Google Drive") {
            try await self.authorizer.authorizeOAuthConnector(
                connectorID: "gdrive",
                name: "Google Drive",
                type: "gdrive_api",
                definition: .google(clientID: self.driveClientID),
                provider: .google,
                clientID: self.driveClientID,
                clientSecret: nil,
                tenant: nil,
                targetPath: self.driveFolderID.nilIfBlank
            )
        }
    }

    func authorizeOneDrive() async {
        await runAuthorization(label: "OneDrive") {
            try await self.authorizer.authorizeOAuthConnector(
                connectorID: "onedrive",
                name: "OneDrive",
                type: "onedrive_api",
                definition: .microsoft(clientID: self.oneDriveClientID, tenant: self.oneDriveTenant.nilIfBlank),
                provider: .microsoft,
                clientID: self.oneDriveClientID,
                clientSecret: nil,
                tenant: self.oneDriveTenant.nilIfBlank,
                targetPath: self.oneDriveFolderPath.nilIfBlank
            )
        }
    }

    /// 浏览器授权（Notion）：授权后 token 进钥匙串，随后再挑数据库与属性。
    func authorizeNotion() async {
        let config = notionConfig()
        await runAuthorization(label: "Notion") {
            try await self.authorizer.authorizeNotionConnector(
                connectorID: "notion",
                name: "Notion",
                definition: .notion(clientID: self.notionClientID),
                clientID: self.notionClientID,
                clientSecret: self.notionClientSecret,
                config: config
            )
        }
    }

    /// 授权完成后保存数据库与属性映射（不需要重新授权）。
    func saveNotionProperties() async {
        guard !notionDatabaseID.isEmpty else {
            showStatus("请先选择或填写目标数据库", isError: true)
            return
        }
        do {
            let config = notionConfig()
            let account = (try await connectorRepository.fetch(id: "notion"))?.keychainAccountRef ?? "notion.token"
            try await connectorRepository.upsert(ConnectorRecord(
                id: "notion",
                name: "Notion",
                connectorType: "notion",
                keychainAccountRef: account,
                configJSON: String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            ))
            await reloadConnectors()
            showStatus("已保存 Notion 数据库与属性映射")
        } catch {
            showStatus("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func notionConfig() -> NotionConnector.Config {
        NotionConnector.Config(
            databaseID: notionDatabaseID,
            titleProperty: notionTitleProperty.isEmpty ? "Name" : notionTitleProperty,
            urlProperty: notionUrlProperty.nilIfBlank,
            tagsProperty: notionTagsProperty.nilIfBlank,
            categoryProperty: notionCategoryProperty.nilIfBlank,
            summaryProperty: notionSummaryProperty.nilIfBlank
        )
    }

    private func runAuthorization(
        label: String = "连接器",
        _ work: @escaping () async throws -> ConnectorAuthorizationCoordinator.Outcome
    ) async {
        isAuthorizing = true
        defer { isAuthorizing = false }
        NovPoolLog.write("授权：开始（\(label)）")
        do {
            let outcome = try await work()
            await reloadConnectors()
            showStatus(outcome.detail)
            NovPoolLog.write("授权：成功 - \(outcome.detail)")
        } catch {
            let message = (error as? NovPoolError)?.errorDescription ?? error.localizedDescription
            showStatus("授权失败：\(message)", isError: true)
            NovPoolLog.write("授权：失败 - \(message)")
        }
    }

    /// 登记一个云端连接器（凭据写入 Keychain，配置只存非敏感字段）。
    func upsertRemoteConnector(
        id: String,
        name: String,
        type: String,
        configJSON: String,
        token: String? = nil,
        credentials: OAuthCredentials? = nil
    ) async {
        do {
            var keychainAccount: String?
            if let credentials {
                let account = "\(id).oauth"
                try keychain.store(try credentials.encoded(), account: account)
                keychainAccount = account
            } else if let token, !token.isEmpty {
                let account = "\(id).token"
                try keychain.store(token, account: account)
                keychainAccount = account
            }
            try await connectorRepository.upsert(ConnectorRecord(
                id: id,
                name: name,
                connectorType: type,
                keychainAccountRef: keychainAccount,
                configJSON: configJSON
            ))
            await reloadConnectors()
            showStatus("已保存连接器：\(name)")
        } catch {
            showStatus("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    func setEnabled(_ isEnabled: Bool, connectorID: String) async {
        try? await connectorRepository.setEnabled(isEnabled, id: connectorID)
        await reloadConnectors()
    }

    func delete(connectorID: String) async {
        try? await connectorRepository.delete(id: connectorID)
        await reloadConnectors()
        showStatus("已删除连接器：\(connectorID)")
    }

    // MARK: - 重新总结

    /// 对尚无 AI 摘要、但已有正文/OCR 的条目重新跑总结；失败原因写进状态栏。
    func resummarizeMissingSummaries() async {
        guard !isResummarizing else { return }
        isResummarizing = true
        defer { isResummarizing = false }
        showStatus("正在重新总结…")
        let message = await resummarizeMissingHandler?() ?? "重新总结未接线"
        let isError = message.contains("失败") || message.contains("未接线")
        showStatus(message, isError: isError && !message.contains("成功"))
    }

    /// 用本机常见路径填充空的 llama-server / 模型字段。
    func fillDetectedLocalLLMPaths() {
        var filled: [String] = []
        if localLLM.configuration.binaryPath.trimmingCharacters(in: .whitespaces).isEmpty,
           let binary = LocalLLMConfiguration.firstExistingBinaryPath() {
            localLLM.configuration.binaryPath = binary
            filled.append("二进制")
        }
        if localLLM.configuration.modelPath.trimmingCharacters(in: .whitespaces).isEmpty,
           let model = LocalLLMConfiguration.firstExistingModelPath() {
            localLLM.configuration.modelPath = model
            filled.append("模型")
        }
        if filled.isEmpty {
            showStatus("未探测到 \(LocalLLMConfiguration.setupHint)", isError: true)
        } else {
            showStatus("已填充：\(filled.joined(separator: "、"))")
        }
    }

    // MARK: - 本机 llama.cpp

    /// 启动本机模型；成功后把 AI 请求指向它（OpenAI 兼容接口，完全不出网）。
    func startLocalLLM() async {
        if let problem = localLLM.start() {
            showStatus(problem, isError: true)
            NovPoolLog.write("llama.cpp：启动失败 - \(problem)")
            return
        }
        prefersLocalLLM = true
        defaults.set(true, forKey: "novpool.llama.enabled")
        defaults.set(localLLM.configuration.baseURL.absoluteString, forKey: "novpool.openai.baseURL")
        defaults.set(localLLM.configuration.modelName, forKey: "novpool.ai.chatModel")
        openAIBaseURL = localLLM.configuration.baseURL.absoluteString
        chatModel = localLLM.configuration.modelName
        let detail = await localLLM.probe()
        showStatus("已启动本机模型（\(localLLM.configuration.modelName)）：\(detail)")
        NovPoolLog.write("llama.cpp：已启动，\(localLLM.configuration.baseURL.absoluteString) - \(detail)")
    }

    func stopLocalLLM() {
        localLLM.stop()
        showStatus("已停止本机模型服务")
        NovPoolLog.write("llama.cpp：已停止")
    }

    func testLocalLLM() async {
        let detail = await localLLM.probe()
        showStatus(detail)
        NovPoolLog.write("llama.cpp：探测 - \(detail)")
    }

    // MARK: - 扇区槽位

    func saveZones() {
        let sanitized = DropZoneConfiguration.sanitize(zoneDrafts)
        zoneDrafts = sanitized
        defaults.set(DropZoneConfiguration.encode(sanitized), forKey: DropZoneConfiguration.defaultsKey)
        showStatus("已保存 \(sanitized.count) 个扇区槽位（重启 NovPool 后生效）")
    }

    func resetZones() {
        zoneDrafts = DropZone.defaultZones
        defaults.removeObject(forKey: DropZoneConfiguration.defaultsKey)
        showStatus("已恢复默认扇区槽位（重启 NovPool 后生效）")
    }

    func pruneFinishedJobs(olderThanDays days: Int = 7) async {
        let repository = OutboxRepository(database: database)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let removed = (try? await repository.pruneFinished(olderThan: cutoff)) ?? 0
        await reloadQueue()
        showStatus("已清理 \(removed) 条已完成任务")
    }

    func showStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }

    private func parseCategories(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    /// 空串与纯空白都当作「未填写」。
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
