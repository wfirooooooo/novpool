import AppKit
import NovPoolCore
import NovPoolUI
import SwiftUI

/// 设置中心：连接器、路由与同步、检索与 AI、维护。
struct SettingsView: View {
    @Bindable var store: AppSettingsStore
    var onRunSyncNow: () async -> String
    var onResetPanelPosition: () -> Void
    var onRevealDataDirectory: () -> Void
    var logPath: String

    @State private var selectedTab = Tab.connectors
    @State private var newNamingTemplate = "{Category}/{YYYY}-{MM}/{Title}.{ext}"
    @State private var isChoosingDirectory = false

    private enum Tab: String, CaseIterable, Identifiable {
        case connectors = "连接器"
        case routing = "路由与同步"
        case intelligence = "检索与 AI"
        case maintenance = "维护"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            Form {
                switch selectedTab {
                case .connectors: connectorsTab
                case .routing: routingTab
                case .intelligence: intelligenceTab
                case .maintenance: maintenanceTab
                }
            }
            .formStyle(.grouped)

            statusBar
        }
        .frame(width: 640, height: 480)
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

    // MARK: - 连接器

    @ViewBuilder
    private var connectorsTab: some View {
        Section("已配置的目标端") {
            if store.connectors.isEmpty {
                Text("还没有目标端。至少添加一个本地归档目录就能开始同步。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.connectors) { connector in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: connector.connectorType))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.name)
                        Text("\(connector.connectorType) · \(connector.id)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用", isOn: Binding(
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
                    .help("删除该连接器")
                }
            }
        }

        Section("添加本地归档目录（不需要授权，落盘即同步）") {
            TextField("命名模板", text: $newNamingTemplate)
                .font(.system(size: 11, design: .monospaced))
            Button("选择目录…") { chooseDirectory() }
                .disabled(isChoosingDirectory)
            Text("可选 Google Drive / OneDrive 的本地挂载目录（~/Library/CloudStorage）、iCloud 云盘，或任意 Obsidian 库。访问权限用安全作用域书签持久化。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        notionSection
        driveSection
        oneDriveSection
        zonesSection
    }

    // MARK: - 云端连接器表单

    @ViewBuilder
    private var notionSection: some View {
        Section("Notion（浏览器授权，无需手填令牌）") {
            TextField("Integration Client ID", text: $store.notionClientID)
            SecureField("Integration Client Secret", text: $store.notionClientSecret)
            Button(store.isAuthorizing ? "等待浏览器授权…" : "用浏览器授权 Notion") {
                Task { await store.authorizeNotion() }
            }
            .disabled(store.isAuthorizing)
            Text("点击后会在浏览器打开 Notion 授权页；登录并允许后自动回到本应用完成登记。Client ID / Secret 来自你在 Notion 建好的 Public Integration（属于应用配置，填一次即可）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }

        Section("Notion 数据库与属性") {
            HStack {
                TextField("数据库 ID", text: $store.notionDatabaseID)
                Button(store.isFetchingNotionDatabases ? "拉取中…" : "拉取数据库") {
                    Task { await store.fetchNotionDatabases() }
                }
                .disabled(store.isFetchingNotionDatabases)
            }
            if !store.notionDatabases.isEmpty {
                Picker("选择数据库", selection: $store.notionDatabaseID) {
                    ForEach(store.notionDatabases) { database in
                        Text(database.title).tag(database.id)
                    }
                }
            }
            TextField("标题属性名", text: $store.notionTitleProperty)
            TextField("URL 属性名（可选）", text: $store.notionUrlProperty)
            TextField("标签属性名（multi_select，可选）", text: $store.notionTagsProperty)
            TextField("分类属性名（select，可选）", text: $store.notionCategoryProperty)
            TextField("摘要属性名（rich_text，可选）", text: $store.notionSummaryProperty)
            Button("保存数据库与属性") { Task { await store.saveNotionProperties() } }
        }
    }

    @ViewBuilder
    private var driveSection: some View {
        Section("Google Drive（浏览器授权，无需手填令牌）") {
            TextField("目标文件夹 ID（可选，留空为根目录）", text: $store.driveFolderID)
            TextField("OAuth Client ID", text: $store.driveClientID)
            Button(store.isAuthorizing ? "等待浏览器授权…" : "用浏览器授权 Google Drive") {
                Task { await store.authorizeGoogleDrive() }
            }
            .disabled(store.isAuthorizing)
        }
    }

    @ViewBuilder
    private var oneDriveSection: some View {
        Section("OneDrive（浏览器授权，无需手填令牌）") {
            TextField("租户（默认 common）", text: $store.oneDriveTenant)
            TextField("目标路径（例如 NovPool/技术）", text: $store.oneDriveFolderPath)
            TextField("OAuth Client ID", text: $store.oneDriveClientID)
            Button(store.isAuthorizing ? "等待浏览器授权…" : "用浏览器授权 OneDrive") {
                Task { await store.authorizeOneDrive() }
            }
            .disabled(store.isAuthorizing)
        }
    }

    /// 悬浮窗拖拽展开的槽位：标题、图标、绑定到哪个连接器。
    @ViewBuilder
    private var zonesSection: some View {
        Section("悬浮窗扇区槽位（最多 \(DropZoneConfiguration.maximumZones) 个）") {
            ForEach(store.zoneDrafts.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("标题", text: Binding(
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
                    Picker("目标", selection: Binding(
                        get: { store.zoneDrafts[index].connectorID ?? "" },
                        set: { store.zoneDrafts[index].connectorID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("智能路由").tag("")
                        ForEach(store.connectors) { connector in
                            Text(connector.id).tag(connector.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("保存槽位") { store.saveZones() }
                Button("恢复默认") { store.resetZones() }
                Text("智能路由 = 交给路由规则决定；绑定连接器 = 拖到该槽位强制送往它。")
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
        panel.prompt = "作为归档目录"
        panel.message = "选择本地云盘挂载目录或 Obsidian 库"
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

    // MARK: - 路由与同步

    @ViewBuilder
    private var routingTab: some View {
        Section("同步") {
            Toggle("启用后台同步（发件箱工作器）", isOn: $store.isSyncEnabled)
            HStack {
                Button("立即同步一轮") {
                    Task {
                        let summary = await onRunSyncNow()
                        store.showStatus(summary)
                        await store.reloadQueue()
                    }
                }
                Spacer()
                Text(queueSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }

        Section("默认目标端") {
            TextField("连接器 ID，逗号分隔（无规则命中时使用）", text: $store.defaultConnectorIDsText)
                .font(.system(size: 11, design: .monospaced))
        }

        Section("路由规则（JSON）") {
            TextEditor(text: $store.routeRulesJSON)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
            HStack {
                Button("校验") { store.validateRouteRules() }
                Button("填入示例") { store.routeRulesJSON = Self.sampleRules }
                Spacer()
                Button("保存设置") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text("按优先级匹配内容类型 / 分类 / 标签 / 来源 App / 关键词；命中后按目标顺序推送——文件型连接器会自动排到前面，其云端链接随后注入下游（例如先传网盘、再把链接写进 Notion）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    static let sampleRules = """
    [
      {
        "id": "pdf-to-cloud",
        "name": "PDF 先传网盘再进 Notion",
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
        "name": "技术内容进 Notion",
        "priority": 5,
        "isEnabled": true,
        "contentTypes": [],
        "categories": ["技术"],
        "tags": [],
        "sourceAppBundleIDs": [],
        "keywords": [],
        "targetConnectorIDs": ["notion"]
      }
    ]
    """

    private var queueSummary: String {
        guard !store.queueCounts.isEmpty else { return "队列为空" }
        let order = ["PENDING", "BLOCKED", "RUNNING", "SUCCEEDED", "FAILED"]
        return order
            .compactMap { key in store.queueCounts[key].map { "\(key.lowercased()) \($0)" } }
            .joined(separator: " · ")
    }

    // MARK: - 检索与 AI

    @ViewBuilder
    private var intelligenceTab: some View {
        Section("全局快捷键") {
            TextField("例如 cmd+shift+space", text: $store.searchHotKey)
                .font(.system(size: 11, design: .monospaced))
            Text(validHotKey ? "写法可用" : "写法无效：需要「修饰键+主键」，例如 cmd+shift+space")
                .font(.system(size: 10))
                .foregroundStyle(validHotKey ? Color.secondary : Color.red)
        }

        Section("AI 增强") {
            Toggle("启用摘要 / 分类 / 标签 / 向量", isOn: $store.isAIEnabled)
            TextField("分类树（顿号分隔，限定 category 取值范围）", text: $store.categoriesText)
            TextField("对话模型", text: $store.chatModel)
            TextField("向量模型", text: $store.embeddingModel)
            TextField("Ollama 地址", text: $store.ollamaBaseURL)
        }

        Section("OpenAI 兼容接口（留空则用本地 Ollama）") {
            TextField("Base URL", text: $store.openAIBaseURL)
            SecureField("API Key（仅保存在本机偏好设置）", text: $store.openAIAPIKey)
        }

        localLLMSection

        Section {
            Button("保存设置") { store.save() }
        }
    }

    /// 本机 llama.cpp：选择 llama-server 与 .gguf，一键拉起（OpenAI 兼容，完全不出网）。
    @ViewBuilder
    private var localLLMSection: some View {
        Section("本机 llama.cpp 模型") {
            HStack(spacing: 8) {
                TextField("llama-server 可执行文件", text: Binding(
                    get: { store.localLLM.configuration.binaryPath },
                    set: { store.localLLM.configuration.binaryPath = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                Button("选择…") { chooseFile { store.localLLM.configuration.binaryPath = $0.path } }
            }
            HStack(spacing: 8) {
                TextField("模型文件（.gguf）", text: Binding(
                    get: { store.localLLM.configuration.modelPath },
                    set: { store.localLLM.configuration.modelPath = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                Button("选择…") { chooseFile { store.localLLM.configuration.modelPath = $0.path } }
            }
            HStack(spacing: 8) {
                TextField("端口", value: Binding(
                    get: { store.localLLM.configuration.port },
                    set: { store.localLLM.configuration.port = $0 }
                ), format: .number)
                .frame(width: 80)
                TextField("上下文长度（0 = 默认）", value: Binding(
                    get: { store.localLLM.configuration.contextSize },
                    set: { store.localLLM.configuration.contextSize = $0 }
                ), format: .number)
                .frame(width: 120)
                TextField("额外参数（如 --threads 8 --n-gpu-layers 99）", text: Binding(
                    get: { store.localLLM.configuration.extraArguments },
                    set: { store.localLLM.configuration.extraArguments = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button(store.localLLM.isRunning ? "停止服务" : "启动模型") {
                    Task {
                        if store.localLLM.isRunning {
                            store.stopLocalLLM()
                        } else {
                            await store.startLocalLLM()
                        }
                    }
                }
                Button("测试连接") { Task { await store.testLocalLLM() } }
                Text(store.localLLM.isRunning ? "运行中 · \(store.localLLM.configuration.baseURL.absoluteString)" : "未运行")
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
            Text("启动成功后 AI 请求会自动指向本机服务（模型名用文件名），摘要与标签完全离线生成。")
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

    // MARK: - 维护

    @ViewBuilder
    private var maintenanceTab: some View {
        Section("悬浮窗") {
            Button("重置悬浮窗位置") { onResetPanelPosition() }
        }
        Section("数据") {
            Button("在访达中打开知识库目录") { onRevealDataDirectory() }
            Text("启动日志：\(logPath)")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        Section("缓存清理") {
            Button("清理 7 天前已完成的同步任务") {
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
