import Foundation

/// UI language (Chinese / English in Settings).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case zh
    case en

    var id: String { rawValue }

    static let defaultsKey = "novpool.ui.language"

    var displayName: String {
        switch self {
        case .zh: "中文"
        case .en: "English"
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> AppLanguage {
        if let raw = defaults.string(forKey: defaultsKey), let value = AppLanguage(rawValue: raw) {
            return value
        }
        return .en
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// AI backend: only one active at a time.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openAICompatible
    case localLlama

    var id: String { rawValue }

    static let defaultsKey = "novpool.ai.provider"

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.ollama, .zh): "Ollama（本地服务）"
        case (.ollama, .en): "Ollama (local server)"
        case (.openAICompatible, .zh): "OpenAI 兼容接口"
        case (.openAICompatible, .en): "OpenAI-compatible API"
        case (.localLlama, .zh): "本机 llama.cpp"
        case (.localLlama, .en): "Local llama.cpp"
        }
    }

    /// Infer from existing prefs; migrate older keys when no explicit provider is stored.
    static func load(_ defaults: UserDefaults = .standard) -> AIProvider {
        if let raw = defaults.string(forKey: defaultsKey), let value = AIProvider(rawValue: raw) {
            return value
        }
        if defaults.bool(forKey: "novpool.llama.enabled") {
            return .localLlama
        }
        if let url = defaults.string(forKey: "novpool.openai.baseURL"), !url.isEmpty {
            return .openAICompatible
        }
        return .ollama
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Lightweight Settings / menu-bar copy table (zh / en).
enum AppL10n {
    enum Key: String {
        case tabLibrary, tabIntelligence, tabRouting, tabCloud, tabMaintenance
        case language, languageHint, languageSwitched
        case aiMaster, aiProviderHint, aiBackendHeader, aiEnrichmentHeader
        case aiCategories, aiCategoriesHint
        case aiChatModel, aiEmbeddingModel
        case aiOllamaURL, aiOpenAIBase, aiOpenAIKey
        case aiResummarize, aiResummarizeHint, working
        case aiLocalURL, aiLocalURLHint
        case aiLocalLaunchOptional, aiLocalCommandHint
        case aiLocalBinary, aiLocalModel, aiLocalPort, aiLocalContext, aiLocalExtra
        case aiStart, aiStop, aiTest, aiFillPaths, aiRunning, aiNotRunning, aiCopyCommand
        case aiLocalHint, chooseEllipsis, launchCommandCopied
        case saveSettings
        case hotkey, hotkeyValid, hotkeyInvalid
        case menuSearch, menuSettings, menuShowPanel, menuHidePanel, menuResetPanel
        case menuDataDir, menuArchiveDir, menuQuit, menuStarting
        case maintenancePanel, maintenanceResetPanel, maintenanceData, maintenanceReveal
        case maintenanceLog, maintenanceCache, maintenancePrune
    }

    static func t(_ key: Key, _ language: AppLanguage) -> String {
        switch (key, language) {
        case (.tabLibrary, .zh): "本机知识库"
        case (.tabLibrary, .en): "Library"
        case (.tabIntelligence, .zh): "检索与 AI"
        case (.tabIntelligence, .en): "Search & AI"
        case (.tabRouting, .zh): "路由"
        case (.tabRouting, .en): "Routing"
        case (.tabCloud, .zh): "云端（可选）"
        case (.tabCloud, .en): "Cloud (optional)"
        case (.tabMaintenance, .zh): "维护"
        case (.tabMaintenance, .en): "Maintenance"

        case (.language, .zh): "界面语言"
        case (.language, .en): "Language"
        case (.languageHint, .zh): "切换后设置与菜单文案立即生效；部分系统对话框仍跟系统语言。"
        case (.languageHint, .en): "Settings and menu update immediately. Some system dialogs still follow macOS language."
        case (.languageSwitched, .zh): "界面语言已切换为中文"
        case (.languageSwitched, .en): "Language switched to English"

        case (.aiMaster, .zh): "启用摘要 / 主题分类 / 标签 / 向量"
        case (.aiMaster, .en): "Enable summary / topic / tags / embeddings"
        case (.aiProviderHint, .zh): "以下三个后端一次只能开一个；关闭当前项即停用 AI。"
        case (.aiProviderHint, .en): "Only one backend can be on. Turning the active one off disables AI."
        case (.aiBackendHeader, .zh): "AI 后端（互斥）"
        case (.aiBackendHeader, .en): "AI backend (one at a time)"
        case (.aiEnrichmentHeader, .zh): "AI 增强"
        case (.aiEnrichmentHeader, .en): "AI enrichment"
        case (.aiCategories, .zh): "主题分类树（顿号分隔）"
        case (.aiCategories, .en): "Topic categories (comma separated)"
        case (.aiCategoriesHint, .zh): "按内容含义归类，例如 技术、产品、生活；不是网页/图片/PDF 这类资源形态。"
        case (.aiCategoriesHint, .en): "Classify by topic (e.g. Tech, Product, Life)—not by file type like PDF/image."
        case (.aiChatModel, .zh): "对话模型"
        case (.aiChatModel, .en): "Chat model"
        case (.aiEmbeddingModel, .zh): "向量模型"
        case (.aiEmbeddingModel, .en): "Embedding model"
        case (.aiOllamaURL, .zh): "Ollama 地址"
        case (.aiOllamaURL, .en): "Ollama base URL"
        case (.aiOpenAIBase, .zh): "Base URL"
        case (.aiOpenAIBase, .en): "Base URL"
        case (.aiOpenAIKey, .zh): "API Key（保存在本机钥匙串）"
        case (.aiOpenAIKey, .en): "API Key (stored in Keychain)"
        case (.aiResummarize, .zh): "重新总结缺失摘要"
        case (.aiResummarize, .en): "Re-summarize missing"
        case (.aiResummarizeHint, .zh): "对尚无摘要、但已有正文的条目再跑一轮 AI。"
        case (.aiResummarizeHint, .en): "Re-run AI for items that have body text but no summary yet."
        case (.working, .zh): "正在总结…"
        case (.working, .en): "Working…"
        case (.aiLocalURL, .zh): "Base URL（OpenAI 兼容）"
        case (.aiLocalURL, .en): "Base URL (OpenAI-compatible)"
        case (.aiLocalURLHint, .zh): "与 Ollama 一样填接口地址，默认 http://127.0.0.1:8080/v1。服务可由下方代启，或按命令自行启动。"
        case (.aiLocalURLHint, .en): "Same as Ollama: point to the API root, default http://127.0.0.1:8080/v1. Start below or run the suggested command yourself."
        case (.aiLocalLaunchOptional, .zh): "可选：由 NovPool 启动 llama-server"
        case (.aiLocalLaunchOptional, .en): "Optional: let NovPool start llama-server"
        case (.aiLocalCommandHint, .zh): "终端启动命令（可复制）"
        case (.aiLocalCommandHint, .en): "Terminal launch command (copyable)"
        case (.aiLocalBinary, .zh): "llama-server 可执行文件"
        case (.aiLocalBinary, .en): "llama-server binary"
        case (.aiLocalModel, .zh): "模型文件（.gguf）"
        case (.aiLocalModel, .en): "Model file (.gguf)"
        case (.aiLocalPort, .zh): "端口"
        case (.aiLocalPort, .en): "Port"
        case (.aiLocalContext, .zh): "上下文长度（0 = 默认）"
        case (.aiLocalContext, .en): "Context size (0 = default)"
        case (.aiLocalExtra, .zh): "额外参数（如 --threads 8）"
        case (.aiLocalExtra, .en): "Extra args (e.g. --threads 8)"
        case (.aiStart, .zh): "启动模型"
        case (.aiStart, .en): "Start"
        case (.aiStop, .zh): "停止服务"
        case (.aiStop, .en): "Stop"
        case (.aiTest, .zh): "测试连接"
        case (.aiTest, .en): "Test"
        case (.aiFillPaths, .zh): "填充已探测路径"
        case (.aiFillPaths, .en): "Autofill paths"
        case (.aiRunning, .zh): "运行中"
        case (.aiRunning, .en): "Running"
        case (.aiNotRunning, .zh): "未运行"
        case (.aiNotRunning, .en): "Not running"
        case (.aiCopyCommand, .zh): "复制命令"
        case (.aiCopyCommand, .en): "Copy command"
        case (.aiLocalHint, .zh): "填好 Base URL 并保证 llama-server 在跑即可；摘要与标签完全离线。"
        case (.aiLocalHint, .en): "Set Base URL and keep llama-server running; summaries stay fully offline."
        case (.chooseEllipsis, .zh): "选择…"
        case (.chooseEllipsis, .en): "Choose…"
        case (.launchCommandCopied, .zh): "已复制启动命令"
        case (.launchCommandCopied, .en): "Launch command copied"

        case (.saveSettings, .zh): "保存设置"
        case (.saveSettings, .en): "Save"
        case (.hotkey, .zh): "全局快捷键"
        case (.hotkey, .en): "Global hotkey"
        case (.hotkeyValid, .zh): "写法可用"
        case (.hotkeyValid, .en): "Valid"
        case (.hotkeyInvalid, .zh): "写法无效：需要「修饰键+主键」，例如 cmd+shift+space"
        case (.hotkeyInvalid, .en): "Invalid: need modifiers+key, e.g. cmd+shift+space"

        case (.menuSearch, .zh): "搜索知识库…"
        case (.menuSearch, .en): "Search Knowledge…"
        case (.menuSettings, .zh): "设置…"
        case (.menuSettings, .en): "Settings…"
        case (.menuShowPanel, .zh): "显示悬浮窗"
        case (.menuShowPanel, .en): "Show Drop Zone"
        case (.menuHidePanel, .zh): "隐藏悬浮窗"
        case (.menuHidePanel, .en): "Hide Drop Zone"
        case (.menuResetPanel, .zh): "重置悬浮窗位置"
        case (.menuResetPanel, .en): "Reset Drop Zone Position"
        case (.menuDataDir, .zh): "打开知识库数据目录"
        case (.menuDataDir, .en): "Reveal Data Folder"
        case (.menuArchiveDir, .zh): "打开归档目录"
        case (.menuArchiveDir, .en): "Reveal Staging Folder"
        case (.menuQuit, .zh): "退出 NovPool"
        case (.menuQuit, .en): "Quit NovPool"
        case (.menuStarting, .zh): "正在启动…"
        case (.menuStarting, .en): "Starting…"

        case (.maintenancePanel, .zh): "悬浮窗"
        case (.maintenancePanel, .en): "Drop zone"
        case (.maintenanceResetPanel, .zh): "重置悬浮窗位置"
        case (.maintenanceResetPanel, .en): "Reset drop zone position"
        case (.maintenanceData, .zh): "数据"
        case (.maintenanceData, .en): "Data"
        case (.maintenanceReveal, .zh): "在访达中打开知识库目录"
        case (.maintenanceReveal, .en): "Reveal knowledge folder in Finder"
        case (.maintenanceLog, .zh): "启动日志"
        case (.maintenanceLog, .en): "Log"
        case (.maintenanceCache, .zh): "缓存清理"
        case (.maintenanceCache, .en): "Cleanup"
        case (.maintenancePrune, .zh): "清理 7 天前已完成的同步任务"
        case (.maintenancePrune, .en): "Prune finished sync jobs older than 7 days"
        }
    }
}
