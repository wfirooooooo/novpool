import Foundation
import NovPoolConnectors
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import SwiftUI

/// Read/write entry point for Settings.
///
/// Tunables live in `UserDefaults` (same keys as `NovPoolSettings`);
/// connectors live in the database (credentials in Keychain). The Settings panel
/// goes through this type only, for easier testing and audit.
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
    var aiProvider: AIProvider
    var uiLanguage: AppLanguage
    var categoriesText: String
    var chatModel: String
    var embeddingModel: String
    var ollamaBaseURL: String
    var openAIBaseURL: String
    var openAIAPIKey: String
    var isSyncEnabled: Bool
    var routeRulesJSON: String
    var defaultConnectorIDsText: String

    func t(_ key: AppL10n.Key) -> String {
        AppL10n.t(key, uiLanguage)
    }

    private(set) var connectors: [ConnectorRecord] = []
    private(set) var queueCounts: [String: Int] = [:]
    private(set) var statusMessage: String?
    private(set) var statusIsError = false
    /// Cloud connector auth health (id → status).
    private(set) var authStatuses: [String: ConnectorAuthStatus] = [:]
    private(set) var isProbingAuth = false

    // Cloud connector form drafts
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
    /// Browser OAuth orchestration (session from NovPoolUI; reuses browser login state).
    private let authorizer: ConnectorAuthorizationCoordinator

    /// Drop-zone sector drafts (up to four).
    var zoneDrafts: [DropZone] = []
    /// Local llama.cpp server.
    let localLLM = LocalLLMServerManager()
    var prefersLocalLLM: Bool
    /// Injected by AppEnvironment: batch re-summarize items still missing a summary.
    var resummarizeMissingHandler: (@MainActor () async -> String)?
    /// Injected by AppEnvironment: push persisted settings into running services (hotkey / routes / AI / sync).
    var applyRuntimeHandler: (@MainActor () async -> String)?
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

        let settings = NovPoolSettings.load(defaults, keychain: keychain)
        searchHotKey = defaults.string(forKey: "novpool.hotkey") ?? "cmd+shift+space"
        isAIEnabled = settings.isAIEnabled
        aiProvider = settings.aiProvider
        uiLanguage = settings.uiLanguage
        categoriesText = settings.categories.joined(separator: ", ")
        chatModel = settings.chatModel
        embeddingModel = settings.embeddingModel
        ollamaBaseURL = settings.ollamaBaseURL.absoluteString
        openAIBaseURL = settings.openAIBaseURL?.absoluteString ?? ""
        openAIAPIKey = settings.openAIAPIKey ?? ""
        isSyncEnabled = settings.isSyncEnabled
        routeRulesJSON = settings.routeRulesJSON
        defaultConnectorIDsText = settings.defaultConnectorIDs.joined(separator: ",")
        zoneDrafts = DropZoneConfiguration.zones(from: defaults.string(forKey: DropZoneConfiguration.defaultsKey))
        prefersLocalLLM = settings.aiProvider == .localLlama || defaults.bool(forKey: "novpool.llama.enabled")
        driveClientID = defaults.string(forKey: "novpool.oauth.gdrive.clientID") ?? ""
        driveFolderID = defaults.string(forKey: "novpool.oauth.gdrive.folderID") ?? ""
        oneDriveClientID = defaults.string(forKey: "novpool.oauth.onedrive.clientID") ?? ""
        oneDriveTenant = defaults.string(forKey: "novpool.oauth.onedrive.tenant") ?? "common"
        oneDriveFolderPath = defaults.string(forKey: "novpool.oauth.onedrive.folderPath") ?? "NovPool"
        notionClientID = defaults.string(forKey: "novpool.oauth.notion.clientID") ?? ""
        notionClientSecret = (try? keychain.loadString(account: "notion.oauth.clientSecret")) ?? ""
        notionDatabaseID = defaults.string(forKey: "novpool.notion.databaseID") ?? ""
        notionTitleProperty = defaults.string(forKey: "novpool.notion.titleProperty") ?? "Name"
        notionUrlProperty = defaults.string(forKey: "novpool.notion.urlProperty") ?? ""
        notionTagsProperty = defaults.string(forKey: "novpool.notion.tagsProperty") ?? ""
        notionCategoryProperty = defaults.string(forKey: "novpool.notion.categoryProperty") ?? ""
        notionSummaryProperty = defaults.string(forKey: "novpool.notion.summaryProperty") ?? ""
        authorizer = ConnectorAuthorizationCoordinator(
            session: WebBrowserAuthorizationSession(logger: { NovPoolLog.write($0) }),
            credentials: keychain,
            connectorRepository: connectorRepository
        )
    }

    // MARK: - Load / save

    func reloadConnectors() async {
        connectors = (try? await connectorRepository.list()) ?? []
    }

    /// Probe whether each cloud connector's Keychain credentials are still usable.
    func refreshAuthStatuses() async {
        isProbingAuth = true
        defer { isProbingAuth = false }
        let hub = ConnectorHub(repository: connectorRepository, keychain: keychain)
        var next: [String: ConnectorAuthStatus] = [:]
        for connector in connectors {
            switch connector.connectorType {
            case "notion", "gdrive_api", "onedrive_api":
                next[connector.id] = await hub.probeAuthentication(connectorID: connector.id)
            default:
                continue
            }
        }
        authStatuses = next
    }

    func reloadQueue() async {
        let repository = OutboxRepository(database: database)
        let counts = (try? await repository.statusCounts()) ?? [:]
        queueCounts = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    func save() {
        defaults.set(searchHotKey, forKey: "novpool.hotkey")
        defaults.set(isAIEnabled, forKey: "novpool.ai.enabled")
        aiProvider.save(defaults)
        uiLanguage.save(defaults)
        defaults.set(parseCategories(categoriesText), forKey: "novpool.ai.categories")
        defaults.set(chatModel, forKey: "novpool.ai.chatModel")
        defaults.set(embeddingModel, forKey: "novpool.ai.embeddingModel")
        defaults.set(ollamaBaseURL, forKey: "novpool.ollama.baseURL")
        if openAIBaseURL.isEmpty {
            defaults.removeObject(forKey: "novpool.openai.baseURL")
        } else {
            defaults.set(openAIBaseURL, forKey: "novpool.openai.baseURL")
        }
        defaults.set(aiProvider == .localLlama, forKey: "novpool.llama.enabled")
        do {
            try NovPoolSettings.saveOpenAIAPIKey(openAIAPIKey, defaults: defaults, keychain: keychain)
        } catch {
            showStatus("Failed to write API Key to Keychain: \(error.localizedDescription)", isError: true)
            return
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
        persistOAuthDrafts()
        Task { await applyRuntimeChanges() }
    }

    /// Persist, then hot-push into running services.
    private func applyRuntimeChanges() async {
        if let applyRuntimeHandler {
            let message = await applyRuntimeHandler()
            showStatus(message)
        } else {
            showStatus("Saved (some items need a restart)")
        }
    }

    /// Persist OAuth app config (non-token fields like Client ID) so “Re-authorize” still works after relaunch.
    private func persistOAuthDrafts() {
        defaults.set(driveClientID, forKey: "novpool.oauth.gdrive.clientID")
        defaults.set(driveFolderID, forKey: "novpool.oauth.gdrive.folderID")
        defaults.set(oneDriveClientID, forKey: "novpool.oauth.onedrive.clientID")
        defaults.set(oneDriveTenant, forKey: "novpool.oauth.onedrive.tenant")
        defaults.set(oneDriveFolderPath, forKey: "novpool.oauth.onedrive.folderPath")
        defaults.set(notionClientID, forKey: "novpool.oauth.notion.clientID")
        defaults.set(notionDatabaseID, forKey: "novpool.notion.databaseID")
        defaults.set(notionTitleProperty, forKey: "novpool.notion.titleProperty")
        defaults.set(notionUrlProperty, forKey: "novpool.notion.urlProperty")
        defaults.set(notionTagsProperty, forKey: "novpool.notion.tagsProperty")
        defaults.set(notionCategoryProperty, forKey: "novpool.notion.categoryProperty")
        defaults.set(notionSummaryProperty, forKey: "novpool.notion.summaryProperty")
        let secret = notionClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty {
            try? keychain.delete(account: "notion.oauth.clientSecret")
        } else {
            try? keychain.store(secret, account: "notion.oauth.clientSecret")
        }
    }

    func validateRouteRules() {
        guard !routeRulesJSON.isEmpty else {
            showStatus("Route rules empty: every item uses the default connectors")
            return
        }
        guard let data = routeRulesJSON.data(using: .utf8) else {
            showStatus("Route rules are not valid text", isError: true)
            return
        }
        do {
            let rules = try JSONDecoder().decode([RouteRule].self, from: data)
            showStatus("Route rules OK (\(rules.count) rules)")
        } catch {
            showStatus("Failed to parse route rules: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Connectors

    /// Add a local cloud-mount directory (Google Drive / OneDrive / iCloud / Obsidian vault).
    /// Security-scoped bookmarks persist access across relaunches.
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
            showStatus("Added archive folder: \(directory.lastPathComponent)")
        } catch {
            showStatus("Add failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Cloud connectors

    /// List Notion databases using the Keychain token (OAuth result first, draft token fallback).
    func fetchNotionDatabases() async {
        isFetchingNotionDatabases = true
        defer { isFetchingNotionDatabases = false }
        let token = await resolvedNotionToken()
        guard let token, !token.isEmpty else {
            showStatus("Authorize Notion in the browser first", isError: true)
            return
        }
        let connector = NotionConnector(token: token)
        do {
            let config = NotionConnector.Config(databaseID: notionDatabaseID, titleProperty: notionTitleProperty)
            notionDatabases = try await connector.listDatabases(
                configJSON: try JSONEncoder().encode(config)
            )
            if notionDatabases.isEmpty {
                showStatus("No writable databases for this auth: add the integration to the target database first", isError: true)
            } else {
                showStatus("Fetched \(notionDatabases.count) databases")
            }
        } catch {
            let message = SecretRedactor.redact(
                (error as? NovPoolError)?.errorDescription ?? error.localizedDescription
            )
            showStatus("Failed to fetch databases: \(message)", isError: true)
        }
    }

    private func resolvedNotionToken() async -> String? {
        if let record = try? await connectorRepository.fetch(id: "notion"),
           let account = record.keychainAccountRef,
           let token = try? keychain.loadString(account: account),
           !token.isEmpty {
            return token
        }
        let draft = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? nil : draft
    }

    func saveNotionConnector() async {
        guard !notionToken.isEmpty else {
            showStatus("Enter a Notion Integration Token (starts with ntn_)", isError: true)
            return
        }
        guard !notionDatabaseID.isEmpty else {
            showStatus("Enter or select a target database ID", isError: true)
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
            showStatus("Failed to serialize config: \(error.localizedDescription)", isError: true)
        }
    }

    /// Browser OAuth for Google Drive: user clicks + signs in; tokens land in Keychain.
    func authorizeGoogleDrive() async {
        persistOAuthDrafts()
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
        persistOAuthDrafts()
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

    /// Browser OAuth for Notion: token goes to Keychain, then pick database + properties.
    func authorizeNotion() async {
        persistOAuthDrafts()
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

    /// Re-authorize by connector type (list-row “Re-authorize” button).
    func reauthorize(connectorID: String) async {
        switch connectorID {
        case "gdrive": await authorizeGoogleDrive()
        case "onedrive": await authorizeOneDrive()
        case "notion": await authorizeNotion()
        default:
            showStatus("Unknown connector: \(connectorID)", isError: true)
        }
    }

    /// Save database + property mapping after auth (no re-authorize needed).
    func saveNotionProperties() async {
        guard !notionDatabaseID.isEmpty else {
            showStatus("Select or enter a target database first", isError: true)
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
            showStatus("Saved Notion database and property mapping")
        } catch {
            showStatus("Save failed: \(error.localizedDescription)", isError: true)
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
        label: String = "connector",
        _ work: @escaping () async throws -> ConnectorAuthorizationCoordinator.Outcome
    ) async {
        isAuthorizing = true
        defer { isAuthorizing = false }
        NovPoolLog.write("Auth: start (\(label))")
        do {
            let outcome = try await work()
            await reloadConnectors()
            await refreshAuthStatuses()
            showStatus(outcome.detail)
            NovPoolLog.write("Auth: success - \(outcome.detail)")
        } catch {
            let message = SecretRedactor.redact(
                (error as? NovPoolError)?.errorDescription ?? error.localizedDescription
            )
            showStatus("Authorization failed: \(message)", isError: true)
            NovPoolLog.write("Auth: failed - \(message)")
        }
    }

    /// Register a cloud connector (credentials in Keychain; config stores non-sensitive fields only).
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
            showStatus("Saved connector: \(name)")
        } catch {
            showStatus("Save failed: \(error.localizedDescription)", isError: true)
        }
    }

    func setEnabled(_ isEnabled: Bool, connectorID: String) async {
        try? await connectorRepository.setEnabled(isEnabled, id: connectorID)
        await reloadConnectors()
    }

    func delete(connectorID: String) async {
        if let record = try? await connectorRepository.fetch(id: connectorID),
           let account = record.keychainAccountRef {
            try? keychain.delete(account: account)
        }
        try? await connectorRepository.delete(id: connectorID)
        await reloadConnectors()
        showStatus("Deleted connector: \(connectorID)")
    }

    // MARK: - Re-summarize

    /// Re-run summarization for items with body/OCR but no AI summary; failures go to the status bar.
    func resummarizeMissingSummaries() async {
        guard !isResummarizing else { return }
        isResummarizing = true
        defer { isResummarizing = false }
        showStatus("Re-summarizing…")
        let message = await resummarizeMissingHandler?() ?? "Re-summarize not wired"
        // Match kit status copy (still Chinese in NovPoolKit) and English app strings.
        let isError = message.contains("失败") || message.contains("failed")
            || message.contains("未接线") || message.contains("not wired")
            || message.lowercased().contains("fail")
        let looksSuccessful = message.contains("成功") || message.lowercased().contains("success")
            || message.contains("已处理") || message.lowercased().contains("processed")
        showStatus(message, isError: isError && !looksSuccessful)
    }

    /// Fill empty llama-server / model fields from common local paths.
    func fillDetectedLocalLLMPaths() {
        var filled: [String] = []
        if localLLM.configuration.binaryPath.trimmingCharacters(in: .whitespaces).isEmpty,
           let binary = LocalLLMConfiguration.firstExistingBinaryPath() {
            localLLM.configuration.binaryPath = binary
            filled.append("binary")
        }
        if localLLM.configuration.modelPath.trimmingCharacters(in: .whitespaces).isEmpty,
           let model = LocalLLMConfiguration.firstExistingModelPath() {
            localLLM.configuration.modelPath = model
            filled.append("model")
        }
        if filled.isEmpty {
            showStatus("Not found: \(LocalLLMConfiguration.setupHint)", isError: true)
        } else {
            showStatus("Filled: \(filled.joined(separator: ", "))")
        }
    }

    // MARK: - Mutually exclusive AI backends

    /// Enable one backend (turns others off); `nil` disables AI entirely.
    func selectAIProvider(_ provider: AIProvider?) {
        if let provider {
            if aiProvider == .localLlama, provider != .localLlama, localLLM.isRunning {
                localLLM.stop()
            }
            aiProvider = provider
            isAIEnabled = true
            prefersLocalLLM = provider == .localLlama
            if provider == .localLlama {
                openAIBaseURL = localLLM.configuration.baseURL.absoluteString
                if !localLLM.configuration.modelName.isEmpty {
                    chatModel = localLLM.configuration.modelName
                }
            } else if provider == .ollama {
                let localBase = localLLM.configuration.baseURL.absoluteString
                if openAIBaseURL == localBase {
                    openAIBaseURL = ""
                }
            }
        } else {
            if localLLM.isRunning { localLLM.stop() }
            isAIEnabled = false
            prefersLocalLLM = false
        }
        save()
    }

    /// Binding for exclusive toggles: turn this one on, or turn it off (disable AI).
    func bindingForProvider(_ provider: AIProvider) -> Binding<Bool> {
        Binding(
            get: { self.isAIEnabled && self.aiProvider == provider },
            set: { enabled in
                if enabled {
                    self.selectAIProvider(provider)
                } else if self.aiProvider == provider {
                    self.selectAIProvider(nil)
                }
            }
        )
    }

    // MARK: - Local llama.cpp

    /// Start the local model; point AI requests at its Base URL (OpenAI-compatible, fully offline).
    func startLocalLLM() async {
        selectAIProvider(.localLlama)
        localLLM.configuration.syncAPIBaseURLFromPort()
        if let problem = localLLM.start() {
            showStatus(problem, isError: true)
            NovPoolLog.write("llama.cpp: start failed - \(problem)")
            return
        }
        openAIBaseURL = localLLM.configuration.baseURL.absoluteString
        chatModel = localLLM.configuration.modelName
        defaults.set(openAIBaseURL, forKey: "novpool.openai.baseURL")
        defaults.set(chatModel, forKey: "novpool.ai.chatModel")
        let detail = await localLLM.probe()
        let applied = await applyRuntimeHandler?() ?? "Saved"
        showStatus("Started local model (\(localLLM.configuration.modelName)): \(detail); \(applied)")
        NovPoolLog.write("llama.cpp: started, \(localLLM.configuration.baseURL.absoluteString) - \(detail)")
    }

    func stopLocalLLM() {
        localLLM.stop()
        if aiProvider == .localLlama {
            selectAIProvider(.ollama)
        } else {
            Task { await applyRuntimeChanges() }
        }
        NovPoolLog.write("llama.cpp: stopped")
    }

    func testLocalLLM() async {
        if let problem = localLLM.configuration.apiBaseURLValidationMessage {
            showStatus(problem, isError: true)
            return
        }
        // On test, also point the running AI at this URL.
        openAIBaseURL = localLLM.configuration.baseURL.absoluteString
        selectAIProvider(.localLlama)
        let detail = await localLLM.probe()
        showStatus(detail)
        NovPoolLog.write("llama.cpp: probe \(localLLM.configuration.baseURL.absoluteString) - \(detail)")
    }

    // MARK: - Drop-zone sectors

    func saveZones() {
        let sanitized = DropZoneConfiguration.sanitize(zoneDrafts)
        zoneDrafts = sanitized
        defaults.set(DropZoneConfiguration.encode(sanitized), forKey: DropZoneConfiguration.defaultsKey)
        Task {
            let applied = await applyRuntimeHandler?() ?? "Saved"
            showStatus("Saved \(sanitized.count) drop-zone sectors; \(applied)")
        }
    }

    func resetZones() {
        zoneDrafts = DropZone.defaultZones
        defaults.removeObject(forKey: DropZoneConfiguration.defaultsKey)
        Task {
            let applied = await applyRuntimeHandler?() ?? "Saved"
            showStatus("Restored default drop-zone sectors (local ingest); \(applied)")
        }
    }

    func pruneFinishedJobs(olderThanDays days: Int = 7) async {
        let repository = OutboxRepository(database: database)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let removed = (try? await repository.pruneFinished(olderThan: cutoff)) ?? 0
        await reloadQueue()
        showStatus("Pruned \(removed) finished jobs")
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
    /// Empty or whitespace-only counts as unset.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
