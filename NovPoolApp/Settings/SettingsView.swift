import AppKit
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import SwiftUI

/// Settings: local library first; cloud targets optional.
struct SettingsView: View {
    @Bindable var store: AppSettingsStore
    var onRunSyncNow: () async -> String
    var onResetPanelPosition: () -> Void
    var onRevealDataDirectory: () -> Void
    var logPath: String

    @State private var selectedTab = Tab.library
    @State private var newNamingTemplate = "{Category}/{YYYY}-{MM}/{Title}.{ext}"
    @State private var isChoosingDirectory = false
    @State private var showCloudTargets = false

    private enum Tab: String, CaseIterable, Identifiable {
        case library
        case intelligence
        case routing
        case cloud
        case maintenance

        var id: String { rawValue }

        func title(_ language: AppLanguage) -> String {
            switch self {
            case .library: AppL10n.t(.tabLibrary, language)
            case .intelligence: AppL10n.t(.tabIntelligence, language)
            case .routing: AppL10n.t(.tabRouting, language)
            case .cloud: AppL10n.t(.tabCloud, language)
            case .maintenance: AppL10n.t(.tabMaintenance, language)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title(store.uiLanguage)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            Form {
                switch selectedTab {
                case .library: libraryTab
                case .intelligence: intelligenceTab
                case .routing: routingTab
                case .cloud: cloudTab
                case .maintenance: maintenanceTab
                }
            }
            .formStyle(.grouped)

            statusBar
        }
        .frame(width: 720, height: 520)
        .background(SettingsWindowConfigurator())
        .task {
            await store.reloadConnectors()
            await store.reloadQueue()
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let message = store.statusMessage {
            HStack(spacing: 6) {
                Image(systemName: store.statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(store.statusIsError ? Color.red : Color.secondary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(store.statusIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding([.horizontal, .bottom], 14)
        }
    }

    // MARK: - Library

    @ViewBuilder
    private var libraryTab: some View {
        Section("How to use") {
            Text("Drop files, images, links, or text on the desktop icon → saved locally → ⇧⌘Space to search. Items are tagged by topic (not file type); cloud push is optional.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Button("Reveal knowledge folder in Finder") { onRevealDataDirectory() }
                Button(store.t(.saveSettings)) { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }

        Section("Add local archive folder (optional second copy)") {
            TextField("Naming template", text: $newNamingTemplate)
                .font(.system(size: 11, design: .monospaced))
            Button("Choose folder…") { chooseDirectory() }
                .disabled(isChoosingDirectory)
            Text("Drops already go to Application Support. Pick another folder (e.g. an Obsidian vault) as an extra write target and bind it to a sector below.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        localConnectorsSection
        zonesSection
    }

    @ViewBuilder
    private var localConnectorsSection: some View {
        Section("Configured local targets") {
            let locals = store.connectors.filter { $0.connectorType == "local_mount" }
            if locals.isEmpty {
                Text("No local archive folders yet. You can still use NovPool: drops go into the local library and are searchable.")
                    .foregroundStyle(.secondary)
            }
            ForEach(locals) { connector in
                connectorRow(connector)
            }
        }
    }

    // MARK: - Cloud (optional)

    @ViewBuilder
    private var cloudTab: some View {
        Section("About") {
            Text("Cloud connectors are lower priority for now. These settings still work; everyday local ingest does not depend on them.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Toggle("Show cloud authorization forms", isOn: $showCloudTargets)
        }

        Section("Configured cloud targets") {
            let clouds = store.connectors.filter { $0.connectorType != "local_mount" }
            if clouds.isEmpty {
                Text("No cloud targets yet. Authorize Notion / Drive / OneDrive when you need them.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(store.isProbingAuth ? "Checking…" : "Check authorization") {
                    Task { await store.refreshAuthStatuses() }
                }
                .disabled(store.isProbingAuth)
                Text("Expired auth prompts re-authorize; the outbox stops retrying on auth errors.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(clouds) { connector in
                connectorRow(connector)
            }
        }

        if showCloudTargets {
            notionSection
            driveSection
            oneDriveSection
        }
    }

    @ViewBuilder
    private func connectorRow(_ connector: ConnectorRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: connector.connectorType))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                Text("\(connector.connectorType) · \(connector.id)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let status = store.authStatuses[connector.id] {
                    Text(status.detail.map { "\(status.title): \($0)" } ?? status.title)
                        .font(.system(size: 10))
                        .foregroundStyle(status.needsAttention ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if store.authStatuses[connector.id]?.needsAttention == true {
                Button("Re-authorize") {
                    Task { await store.reauthorize(connectorID: connector.id) }
                }
                .disabled(store.isAuthorizing)
            }
            Toggle("Enabled", isOn: Binding(
                get: { connector.isEnabled },
                set: { value in
                    Task { await store.setEnabled(value, connectorID: connector.id) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button(role: .destructive) {
                Task { await store.delete(connectorID: connector.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this connector (and clear Keychain credentials)")
        }
    }

    // MARK: - Cloud connector forms

    @ViewBuilder
    private var notionSection: some View {
        Section("Notion (browser auth — no manual token)") {
            TextField("Integration Client ID", text: $store.notionClientID)
            SecureField("Integration Client Secret", text: $store.notionClientSecret)
            Button(store.isAuthorizing ? "Waiting for browser…" : "Authorize Notion in browser") {
                Task { await store.authorizeNotion() }
            }
            .disabled(store.isAuthorizing)
            Text("Opens Notion’s authorize page; after you allow access, NovPool finishes registration. Client ID / Secret come from your Public Integration (app config — fill once).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        Section("Notion database & properties") {
            HStack {
                TextField("Database ID", text: $store.notionDatabaseID)
                Button(store.isFetchingNotionDatabases ? "Fetching…" : "Fetch databases") {
                    Task { await store.fetchNotionDatabases() }
                }
                .disabled(store.isFetchingNotionDatabases)
            }
            if !store.notionDatabases.isEmpty {
                Picker("Choose database", selection: $store.notionDatabaseID) {
                    ForEach(store.notionDatabases) { database in
                        Text(database.title).tag(database.id)
                    }
                }
            }
            TextField("Title property", text: $store.notionTitleProperty)
            TextField("URL property (optional)", text: $store.notionUrlProperty)
            TextField("Tags property (multi_select, optional)", text: $store.notionTagsProperty)
            TextField("Category property (select, optional)", text: $store.notionCategoryProperty)
            TextField("Summary property (rich_text, optional)", text: $store.notionSummaryProperty)
            Button("Save database & properties") { Task { await store.saveNotionProperties() } }
        }
    }

    @ViewBuilder
    private var driveSection: some View {
        Section("Google Drive (browser auth — no manual token)") {
            TextField("Target folder ID (optional; empty = root)", text: $store.driveFolderID)
            TextField("OAuth Client ID", text: $store.driveClientID)
            Button(store.isAuthorizing ? "Waiting for browser…" : "Authorize Google Drive in browser") {
                Task { await store.authorizeGoogleDrive() }
            }
            .disabled(store.isAuthorizing)
        }
    }

    @ViewBuilder
    private var oneDriveSection: some View {
        Section("OneDrive (browser auth — no manual token)") {
            TextField("Tenant (default common)", text: $store.oneDriveTenant)
            TextField("Target path (e.g. NovPool/Tech)", text: $store.oneDriveFolderPath)
            TextField("OAuth Client ID", text: $store.oneDriveClientID)
            Button(store.isAuthorizing ? "Waiting for browser…" : "Authorize OneDrive in browser") {
                Task { await store.authorizeOneDrive() }
            }
            .disabled(store.isAuthorizing)
        }
    }

    /// Drop-zone sectors: title, icon, and which connector they bind to.
    @ViewBuilder
    private var zonesSection: some View {
        Section("Drop-zone sectors (max \(DropZoneConfiguration.maximumZones))") {
            ForEach(store.zoneDrafts.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("Title", text: Binding(
                        get: { store.zoneDrafts[index].title },
                        set: { store.zoneDrafts[index].title = $0 }
                    ))
                    .frame(width: 90)
                    TextField("SF Symbol", text: Binding(
                        get: { store.zoneDrafts[index].systemImage },
                        set: { store.zoneDrafts[index].systemImage = $0 }
                    ))
                    .frame(width: 130)
                    .font(.system(size: 11, design: .monospaced))
                    Picker("Target", selection: Binding(
                        get: { store.zoneDrafts[index].connectorID ?? "" },
                        set: { store.zoneDrafts[index].connectorID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Smart routing").tag("")
                        ForEach(store.connectors) { connector in
                            Text(connector.id).tag(connector.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("Save sectors") { store.saveZones() }
                Button("Restore defaults") { store.resetZones() }
                Text("Default “Local ingest” does not push to cloud. Binding a connector forces drops on that sector to it (including local archive folders).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseDirectory() {
        isChoosingDirectory = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as archive"
        panel.message = "Choose a local cloud-mount folder or Obsidian vault"
        let template = newNamingTemplate
        if panel.runModal() == .OK, let url = panel.url {
            let name = url.lastPathComponent
            let id = "local-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            Task {
                await store.addLocalMountConnector(
                    id: id,
                    name: name,
                    directory: url,
                    namingTemplate: template
                )
                isChoosingDirectory = false
            }
        } else {
            isChoosingDirectory = false
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routingTab: some View {
        Section("Sync (off by default: local ingest only)") {
            Toggle("Enable background sync (outbox worker)", isOn: $store.isSyncEnabled)
            Text("When off, drops stay in the local library. When on and a route hits a connector, local archives or cloud targets are pushed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Button("Sync now") {
                    Task {
                        let summary = await onRunSyncNow()
                        store.showStatus(summary)
                        await store.reloadQueue()
                    }
                }
                .disabled(!store.isSyncEnabled)
                Spacer()
                Text(queueSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }

        Section("Default targets (optional)") {
            TextField("Connector IDs, comma-separated (used when no rule matches; leave empty for local-first)", text: $store.defaultConnectorIDsText)
                .font(.system(size: 11, design: .monospaced))
        }

        Section("Route rules (JSON)") {
            TextEditor(text: $store.routeRulesJSON)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
            HStack {
                Button("Validate") { store.validateRouteRules() }
                Button("Insert sample") { store.routeRulesJSON = Self.sampleRules }
                Spacer()
                Button(store.t(.saveSettings)) { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text("Match by priority on content type / category / tags / source app / keywords; push targets in order — file connectors are sorted first so their cloud URLs can feed downstream (e.g. Drive then Notion).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    static let sampleRules = """
    [
      {
        "id": "pdf-to-cloud",
        "name": "PDF to Drive then Notion",
        "priority": 10,
        "isEnabled": true,
        "contentTypes": ["documentPDF"],
        "categories": [],
        "tags": [],
        "sourceAppBundleIDs": [],
        "keywords": [],
        "targetConnectorIDs": ["gdrive", "notion"]
      },
      {
        "id": "tech-to-notion",
        "name": "Tech content to Notion",
        "priority": 5,
        "isEnabled": true,
        "contentTypes": [],
        "categories": ["Tech"],
        "tags": [],
        "sourceAppBundleIDs": [],
        "keywords": [],
        "targetConnectorIDs": ["notion"]
      }
    ]
    """

    private var queueSummary: String {
        guard !store.queueCounts.isEmpty else { return "Queue empty" }
        let order = ["PENDING", "BLOCKED", "RUNNING", "SUCCEEDED", "FAILED"]
        return order
            .compactMap { key in store.queueCounts[key].map { "\(key.lowercased()) \($0)" } }
            .joined(separator: " · ")
    }

    // MARK: - Search & AI

    @ViewBuilder
    private var intelligenceTab: some View {
        Section(store.t(.hotkey)) {
            TextField("cmd+shift+space", text: $store.searchHotKey)
                .font(.system(size: 11, design: .monospaced))
            Text(validHotKey ? store.t(.hotkeyValid) : store.t(.hotkeyInvalid))
                .font(.system(size: 10))
                .foregroundStyle(validHotKey ? Color.secondary : Color.red)
        }

        Section {
            Toggle(store.t(.aiMaster), isOn: Binding(
                get: { store.isAIEnabled },
                set: { enabled in
                    if enabled {
                        store.selectAIProvider(store.aiProvider)
                    } else {
                        store.selectAIProvider(nil)
                    }
                }
            ))
            Text(store.t(.aiProviderHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            ForEach(AIProvider.allCases) { provider in
                Toggle(provider.title(language: store.uiLanguage), isOn: store.bindingForProvider(provider))
            }
        } header: {
            Text(store.t(.aiBackendHeader))
        }

        Section {
            Text(SummarizeRouteExplanation.text(
                kind: store.isAIEnabled ? store.aiProvider.summarizeRouteKind : .off,
                prefersChinese: store.uiLanguage == .zh
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            TextField(store.t(.aiCategories), text: $store.categoriesText)
            Text(store.t(.aiCategoriesHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(store.t(.aiChatModel), text: $store.chatModel)
            TextField(store.t(.aiEmbeddingModel), text: $store.embeddingModel)
            Stepper(value: $store.digestMaxItems, in: 10...50) {
                Text("\(store.t(.aiDigestLimit)): \(store.digestMaxItems)")
            }
            Text(store.t(.aiDigestLimitHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(store.isResummarizing ? store.t(.working) : store.t(.aiResummarize)) {
                    Task { await store.resummarizeMissingSummaries() }
                }
                .disabled(store.isResummarizing || !store.isAIEnabled)
                Text(store.t(.aiResummarizeHint))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(store.t(.aiEnrichmentHeader))
        }

        if store.aiProvider == .ollama {
            Section("Ollama") {
                TextField(store.t(.aiOllamaURL), text: $store.ollamaBaseURL)
                    .font(.system(size: 11, design: .monospaced))
            }
        }

        if store.aiProvider == .openAICompatible {
            Section(AIProvider.openAICompatible.title(language: store.uiLanguage)) {
                TextField(store.t(.aiOpenAIBase), text: $store.openAIBaseURL)
                    .font(.system(size: 11, design: .monospaced))
                SecureField(store.t(.aiOpenAIKey), text: $store.openAIAPIKey)
            }
        }

        if store.aiProvider == .localLlama {
            localLLMSection
        }

        Section {
            Button(store.t(.saveSettings)) { store.save() }
        }
    }

    /// Local llama.cpp: Base URL primary (same as Ollama); optional managed start or DIY command.
    @ViewBuilder
    private var localLLMSection: some View {
        Section(AIProvider.localLlama.title(language: store.uiLanguage)) {
            TextField(store.t(.aiLocalURL), text: Binding(
                get: { store.localLLM.configuration.apiBaseURL },
                set: { store.localLLM.configuration.apiBaseURL = $0 }
            ))
            .font(.system(size: 11, design: .monospaced))
            Text(store.t(.aiLocalURLHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let urlProblem = store.localLLM.configuration.apiBaseURLValidationMessage {
                Text(urlProblem)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button(store.t(.aiTest)) { Task { await store.testLocalLLM() } }
                Button(store.t(.saveSettings)) {
                    store.openAIBaseURL = store.localLLM.configuration.baseURL.absoluteString
                    store.save()
                }
                Text(store.localLLM.configuration.baseURL.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(store.t(.aiLocalCommandHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Text(store.localLLM.configuration.suggestedLaunchCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(store.t(.aiCopyCommand)) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(store.localLLM.configuration.suggestedLaunchCommand, forType: .string)
                    store.showStatus(store.t(.launchCommandCopied))
                }
            }
            Text(LocalLLMConfiguration.setupHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            DisclosureGroup(store.t(.aiLocalLaunchOptional)) {
                HStack(spacing: 8) {
                    TextField(store.t(.aiLocalBinary), text: Binding(
                        get: { store.localLLM.configuration.binaryPath },
                        set: { store.localLLM.configuration.binaryPath = $0 }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    Button(store.t(.chooseEllipsis)) {
                        chooseFile { store.localLLM.configuration.binaryPath = $0.path }
                    }
                }
                HStack(spacing: 8) {
                    TextField(store.t(.aiLocalModel), text: Binding(
                        get: { store.localLLM.configuration.modelPath },
                        set: { store.localLLM.configuration.modelPath = $0 }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    Button(store.t(.chooseEllipsis)) {
                        chooseFile { store.localLLM.configuration.modelPath = $0.path }
                    }
                }
                HStack(spacing: 8) {
                    TextField(store.t(.aiLocalPort), value: Binding(
                        get: { store.localLLM.configuration.port },
                        set: {
                            store.localLLM.configuration.port = $0
                            store.localLLM.configuration.syncAPIBaseURLFromPort()
                        }
                    ), format: .number)
                    .frame(width: 80)
                    TextField(store.t(.aiLocalContext), value: Binding(
                        get: { store.localLLM.configuration.contextSize },
                        set: { store.localLLM.configuration.contextSize = $0 }
                    ), format: .number)
                    .frame(width: 120)
                    TextField(store.t(.aiLocalExtra), text: Binding(
                        get: { store.localLLM.configuration.extraArguments },
                        set: { store.localLLM.configuration.extraArguments = $0 }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                }
                HStack(spacing: 8) {
                    Button(store.localLLM.isRunning ? store.t(.aiStop) : store.t(.aiStart)) {
                        Task {
                            if store.localLLM.isRunning {
                                store.stopLocalLLM()
                            } else {
                                await store.startLocalLLM()
                            }
                        }
                    }
                    Button(store.t(.aiFillPaths)) { store.fillDetectedLocalLLMPaths() }
                    Text(
                        store.localLLM.isRunning
                            ? "\(store.t(.aiRunning)) · \(store.localLLM.configuration.baseURL.absoluteString)"
                            : store.t(.aiNotRunning)
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                if let problem = store.localLLM.configuration.validationMessage {
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !store.localLLM.recentOutput.isEmpty {
                    ScrollView {
                        Text(store.localLLM.recentOutput.joined(separator: "\n"))
                            .font(.system(size: 9.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 80)
                }
            }

            Text(store.t(.aiLocalHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFile(_ assign: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            assign(url)
        }
    }

    private var validHotKey: Bool {
        HotKeySpec(named: store.searchHotKey) != nil
    }

    // MARK: - Maintenance

    @ViewBuilder
    private var maintenanceTab: some View {
        Section(store.t(.language)) {
            Picker(store.t(.language), selection: $store.uiLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.uiLanguage) { _, language in
                language.save()
                store.showStatus(store.t(.languageSwitched))
            }
            Text(store.t(.languageHint))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        Section(store.t(.maintenancePanel)) {
            Button(store.t(.maintenanceResetPanel)) { onResetPanelPosition() }
        }
        Section(store.t(.maintenanceData)) {
            Button(store.t(.maintenanceReveal)) { onRevealDataDirectory() }
            Text("\(store.t(.maintenanceLog)): \(logPath)")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        Section(store.t(.maintenanceCache)) {
            Button(store.t(.maintenancePrune)) {
                Task { await store.pruneFinishedJobs(olderThanDays: 7) }
            }
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "local_mount": "folder"
        case "notion": "doc.richtext"
        case "gdrive_api": "externaldrive.badge.icloud"
        case "onedrive_api": "cloud"
        default: "questionmark.circle"
        }
    }
}
