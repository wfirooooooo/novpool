# NovPool

## 产品一句话

网上看到想留的东西，拖进小工具，以后能查、能理、能总结。

macOS 桌面常驻小工具：用拖拽收集网页、文件、图片、视频、文字等任意想收藏的内容，支持本地存储与云服务同步，方便后续查阅、归纳、整理与总结。工程架构与验收标准见
[novpool-product-and-arch-design.md](novpool-product-and-arch-design.md)；开发交接见 [HANDOFF.md](HANDOFF.md)；后续计划见 [ROADMAP.md](ROADMAP.md)。

当前进度：**Phase 1～4 的核心能力均已实现并通过自动化测试**——
拖拽捕获、端侧多模态清洗与 AI 增强、多云连接器与跨云级联同步、全局混合检索面板、设置中心。
下一阶段按 [ROADMAP.md](ROADMAP.md) 推进：先稳住收集，再强化查阅与整理，最后做真云端与分发。

## 快速开始

```bash
# 1. 单元测试（202 个用例）
./scripts/test.sh

# 2. 装配可双击运行的 app bundle（Release，ad-hoc 签名 + 启动自检）
./scripts/build-app.sh
./scripts/build-app.sh --run          # 构建后直接启动

# 3. 不开 GUI 直接验证整条链路（数据目录 → 建库 → 暂存 → 入库 → 检索）
./build/NovPool.app/Contents/MacOS/NovPool --selftest

# 4. 也可以直接用 Xcode 打开
open NovPool.xcodeproj
```

受限沙盒 / CI 环境（`~/Library` 不可写、不允许嵌套 `sandbox-exec`）追加参数：
`--disable-sandbox --scratch-path /tmp/novpool-build`，并配合 `NOVPOOL_SKIP_DSYM=1`
跳过被内核拒绝的 dSYM 生成步骤。

可用环境变量：`NOVPOOL_APP_DIR`（产物输出目录，默认 `build/`）、
`NOVPOOL_DATA_DIR`（数据根目录，默认 `~/Library/Application Support/NovPool`）、
`NOVPOOL_SKIP_SELFTEST=1`（跳过构建后的启动自检）。

## 排查启动问题

app 是 `LSUIElement` 菜单栏工具：**没有 Dock 图标**，启动后菜单栏会出现一个托盘图标，
同时桌面右下角出现悬浮图标。如果「执行完脚本什么都没看到」：

```bash
# 1. 先跑无界面自检，它会把问题定位到具体环节
./build/NovPool.app/Contents/MacOS/NovPool --selftest

# 2. 看启动日志（每次启动都会追加，含数据目录、建库结果、悬浮窗 frame 与屏幕信息）
tail -40 ~/Library/Logs/NovPool.log
```

启动失败不会再静默退出：会写日志并弹出说明原因的对话框。自检覆盖数据目录可写性、
SQLite 建库与迁移、暂存写入、拖拽入库、全文检索——这条链路就是 app 启动时真实走的路。

## 目录结构

```text
NovPool.xcodeproj            # Xcode 主工程（App target + 本地包引用 + 共享 Scheme）
NovPoolApp/                  # App 入口、装配根、Info.plist、Entitlements
Packages/NovPoolKit/         # 核心 Swift Package（Swift 6 严格并发）
  Sources/NovPoolCore/         领域模型、连接器协议、路由规则引擎、扇区几何（零 UI 依赖）
  Sources/NovPoolStorage/      SQLite(WAL+FTS5) 封装、Staging、Keychain、安全作用域书签、vDSP 向量
  Sources/NovPoolSystemBridge/ 粘贴板解析、浏览器溯源、OCR、正文提取、AI 增强、摄取流水线
  Sources/NovPoolConnectors/   本地云盘挂载直通连接器、命名模板
  Sources/NovPoolUI/           NSPanel 悬浮窗、点击穿透宿主视图、扇区动画、检索面板、全局快捷键
  Tests/NovPoolKitTests/       202 个单元测试
scripts/                     # test.sh / build-app.sh
```

## 检索面板（⇧⌘Space）

菜单栏图标 →「搜索知识库…」，或按全局快捷键呼出。面板出现在鼠标所在屏幕的水平居中偏上位置，
收起时会把焦点还给原先的前台应用。

| 交互 | 行为 |
| :--- | :--- |
| 输入即搜 | 逐键去抖 120ms，检索本地 SQLite（标题 / 正文 / OCR / 摘要 / 标签 / 来源标题） |
| 空查询 | 直接列出最近条目，可当浏览用 |
| ↑ ↓ | 在结果间移动，列表自动滚动到可见位置 |
| ↩ | 打开：网页条目开浏览器、本地文件在访达中定位、纯文本条目退化为复制 |
| 单击 / 双击 | 单击选中并预览，双击直接打开 |
| 右侧详情 | 命中方式、分类、标签、来源、AI 摘要与正文（文本可选中） |
| 「复制」按钮 | 复制「标题 + 摘要 + 来源 + 正文」的 Markdown |
| esc / 点击别处 | 收起面板 |

排序是 **FTS5 全文（BM25）+ Accelerate vDSP 余弦相似度的 RRF 融合**，结果行会标注
「关键词」「语义」或「关键词 + 语义」。RRF 只使用名次，因此天然免疫两种分数的量纲差异；
没有配置向量模型时自动退化为纯全文检索，不会报错。

## 悬浮图标：自由拖动

- **按住图标拖动**即可把悬浮窗放到任意位置（`NSWindow.performDrag(with:)`，显式接管鼠标按下，
  不依赖 `isMovableByWindowBackground` 的启发式判断）。
- 面板是 `.nonactivatingPanel`，**拖动过程同样不抢走当前应用的键盘焦点**。
- **位置会记住**：拖动结束后去抖 0.3s 写入 `UserDefaults`，键名 `novpool.panel.origin`，
  形如 `"1200.0,320.0"`，可以直接 `defaults read com.novpool.app novpool.panel.origin` 查看。
- **拖不丢**：图标被拖出屏幕可见区域时立刻夹回最近的屏幕（保留 8pt 边距）；
  拔掉显示器导致位置失效时，下次启动也会自动吸附回可见区域。
- 菜单栏 →「重置悬浮窗位置」回到默认右下角并清除记录。

### 贴边时扇区怎么办

图标可以贴到屏幕角落，但扇区是绕图标按 84pt 半径展开的——直接展开的话，朝屏幕外的那个槽位
会被裁掉、够不到。处理方式不是把图标推进屏幕里面，而是**展开时把环心朝屏幕内侧平移**
（图标保持不动），平移量由画布尺寸兜住，因此角落位置同样能用全四个槽位。

对应的两条不变量已写进测试，改动几何参数时会立刻报警：

- 默认贴角位置、以及被夹紧到距边缘 8pt 的极限位置，四个槽位矩形都必须完整落在可见区域内；
- 命中判定与布局必须共用同一个环心（否则高亮的槽位和实际投递的槽位会不一致）。

画布也因此从 260pt 放大到 440pt：环半跨度约 117pt，画布必须留出这段平移空间。
画布完全透明、静默态点击穿透，不占桌面视觉空间。

## 摄取与补齐流程（Phase 1 + Phase 2）

拖拽松手后主流程只做毫秒级工作并立即返回，重活全部在后台 Actor 里完成：

```text
拖拽松手
  └─ PasteboardResolver（P0～P3 优先级）
       └─ StagingStore（原子写入 + SHA256 去重）
            └─ BrowserContextExtractor（150ms 熔断溯源）
                 └─ 落库 knowledge_items  ← 悬浮窗此时提示「已收录」（不阻塞）
                      └─ EnrichmentPipeline（后台）
                           ├─ 图片    → Vision ANE OCR（中英混排，阅读顺序重排）
                           ├─ PDF     → 文字层优先；扫描件才栅格化 + OCR
                           ├─ 网页链接 → URLSession 抓取 + 字符集嗅探 + 正文打分 + Markdown
                           ├─ 纯文本/片段 → 直接进入 AI
                           └─ AIEnhancementService
                                ├─ Ollama / OpenAI 兼容接口（JSON 结构化输出）
                                ├─ 归一化：分类树校验、标签去重限量、摘要截断
                                └─ 向量：配置模型 → NLEmbedding 句向量兜底
                                     └─ updateEnrichment 回填 + FTS5 触发器同步
                                          └─ 悬浮窗提示「已补齐 OCR·正文·AI 标签·向量」
```

## Phase 1 已交付能力

| 能力 | 落点 | 状态 |
| :--- | :--- | :--- |
| 无焦点悬浮面板（`.nonactivatingPanel`，固定 260×260 画布） | `NovPoolUI/NovPoolPanel.swift` | 已实现 |
| 像素级点击穿透（`hitTest` 双态命中区域） | `NovPoolUI/PassthroughHostingView.swift` | 已实现 |
| 拖拽悬停 150ms 弹性展开四扇区 + 角度命中高亮 | `NovPoolUI/DragReceivingView.swift`、`PanelRootView.swift` | 已实现 |
| P0～P3 四级 UTI 优先级解析 | `NovPoolSystemBridge/PasteboardResolver.swift` | 已实现并测试 |
| Staging 原子写入 + SHA256 去重 | `NovPoolStorage/StagingStore.swift` | 已实现并测试 |
| 浏览器静默溯源（Chromium / Safari / Firefox-AX，150ms 熔断） | `NovPoolSystemBridge/BrowserContextExtractor.swift` | 已实现并测试 |
| Schema v1：`knowledge_items` / FTS5 / `connectors` / `sync_outbox_jobs` | `NovPoolStorage/SchemaMigration.swift` | 已实现并测试 |
| 扇区强制路由 + 规则匹配路由 | `NovPoolCore/RouteRules.swift` | 已实现并测试 |
| 本地云盘挂载直通连接器（Obsidian / 云盘目录） | `NovPoolConnectors/LocalCloudMountConnector.swift` | 已实现并测试 |
| 悬浮图标自由拖动 + 位置持久化 + 越界吸附 | `NovPoolUI/PanelController.swift`、`PanelPositionStore.swift` | 已实现并测试 |
| 贴边时扇区环心朝屏幕内侧平移，四个槽位始终可达 | `NovPoolUI/SectorLayout.swift` | 已实现并测试 |

## Phase 2 已交付能力

| 能力 | 落点 | 状态 |
| :--- | :--- | :--- |
| 端侧 ANE OCR（中英混排，`VNRecognizeTextRequest`） | `NovPoolSystemBridge/VisionOCRService.swift` | 已实现；本机沙盒拿不到 ANE 服务，真机用例自动跳过 |
| OCR 结果按「页 → 行 → 列」重排 + 中英空格规则 | `NovPoolSystemBridge/TextRecognition.swift` | 已实现并测试 |
| 扫描版 PDF 逐页栅格化（2x，页数上限） | `NovPoolSystemBridge/PDFContentExtractor.swift` | 已实现并测试 |
| 数字版 PDF 直接读文字层（不消耗 OCR 算力） | `NovPoolSystemBridge/PDFContentExtractor.swift` | 已实现并测试 |
| HTML → Markdown（标题/列表/代码/引用/表格/图片/任务列表） | `NovPoolSystemBridge/MarkdownRenderer.swift` | 已实现并测试 |
| 正文容器打分提取（链接密度 + 段落密度 + 语义加权） | `NovPoolSystemBridge/ArticleExtractor.swift` | 已实现并测试 |
| 网页抓取：超时、体积上限、Content-Type 过滤、GBK/GB18030 字符集嗅探 | `NovPoolSystemBridge/WebContentFetcher.swift` | 已实现并测试 |
| AI 结构化增强：摘要 / 分类 / 标签 / 向量（Ollama + OpenAI 兼容） | `NovPoolSystemBridge/AIEnhancementService.swift`、`AIProviders.swift` | 已实现并测试 |
| 容错 JSON 解析（围栏、前后文、字段类型异常、分类树校验） | `NovPoolSystemBridge/AIEnrichment.swift` | 已实现并测试 |
| 向量回退链（配置模型 → `NLEmbedding` 句向量） | `NovPoolSystemBridge/AIProviders.swift` | 已实现并测试 |
| 后台补齐与回填（FTS5 触发器自动同步） | `NovPoolSystemBridge/EnrichmentPipeline.swift`、`IngestionOrchestrator.swift` | 已实现并测试 |

## Phase 4 核心已交付能力

| 能力 | 落点 | 状态 |
| :--- | :--- | :--- |
| 全局快捷键（Carbon `RegisterEventHotKey`，无需辅助功能授权） | `NovPoolUI/GlobalHotKey.swift`、`HotKeySpec.swift` | 已实现；可用 `novpool.hotkey` 改键 |
| 无边框毛玻璃检索面板（跟随鼠标所在屏幕、收起归还焦点） | `NovPoolUI/SearchPanel.swift`、`SearchPanelController.swift` | 已实现 |
| 可靠的方向键 / 回车 / esc 导航（AppKit `doCommandBy`，不被输入框吞键） | `NovPoolUI/SearchFieldView.swift` | 已实现 |
| FTS5 + vDSP 余弦相似度混合检索（RRF 融合） | `NovPoolStorage/KnowledgeSearchService.swift`、`RankFusion.swift` | 已实现并测试 |
| 命中方式标注、详情预览、打开 / 复制动作解析 | `NovPoolUI/SearchPanelView.swift`、`NovPoolStorage/KnowledgeSearchResult.swift` | 已实现并测试 |
| 空查询浏览最近条目、短查询 LIKE 兜底、向量维度不一致保护 | `KnowledgeSearchService` | 已实现并测试 |

## Phase 3：多云推送与跨云级联

| 能力 | 落点 | 状态 |
| :--- | :--- | :--- |
| 事务性发件箱工作器（轮询、指数退避、重试上限） | `NovPoolConnectors/OutboxSyncWorker.swift` | 已实现并测试 |
| 跨云级联：`dependsOnJobID` 等待、外链注入下游 `upstreamAssetURL` | `OutboxSyncWorker` + `OutboxRepository` | 已实现并测试 |
| 前置失败时级联终止（不留僵尸任务） | `OutboxRepository.failDependents` | 已实现并测试 |
| 连接器中枢：按 `connectors` 表装配实现，凭据取自 Keychain | `NovPoolConnectors/ConnectorHub.swift` | 已实现并测试 |
| Notion：属性映射 + Markdown→原生 Block + 分批追加 + 数据库列表 | `NotionConnector.swift`、`NotionBlocks.swift` | 已实现并测试 |
| Google Drive：multipart / resumable 上传，回执取 `webViewLink` | `CloudDriveConnectors.swift` | 已实现并测试 |
| OneDrive：小文件直传 / `createUploadSession` 分片上传 | `CloudDriveConnectors.swift` | 已实现并测试 |
| OAuth 2.0 + PKCE（CryptoKit S256）、令牌刷新、Keychain 存储 | `OAuth.swift`、`KeychainStore.swift` | 已实现并测试 |
| 命令行配置入口（脚本化登记连接器、查看队列、手动同步） | `NovPoolApp/ConnectorCLI.swift` | 已实现并测试 |
| 设置中心：连接器管理、路由规则、快捷键、AI、缓存清理 | `NovPoolApp/Settings/` | 已实现 |

### 配置云端连接器

图形界面里可以直接添加**本地归档目录**（Google Drive / OneDrive 的 `~/Library/CloudStorage` 挂载点、
iCloud 云盘、Obsidian 库），访问权限用安全作用域书签持久化，不需要任何 OAuth。

需要 API 的连接器用命令行登记（凭据写入系统钥匙串，**不落数据库**）：

```bash
BIN=./build/NovPool.app/Contents/MacOS/NovPool

# Notion：databaseID 是目标数据库（设置里可先看 listDatabases）
$BIN --add-connector '{"id":"notion","name":"Notion 技术库","type":"notion",
  "config":{"databaseID":"…","titleProperty":"名称","tagsProperty":"标签","categoryProperty":"分类","summaryProperty":"摘要"},
  "token":"ntn_…"}'

# Google Drive：oauth 里放刷新令牌，config.folderID 指定目标文件夹
$BIN --add-connector '{"id":"gdrive","name":"Google Drive","type":"gdrive_api",
  "config":{"folderID":"…"},
  "oauth":{"provider":"google","clientID":"…","clientSecret":"…","refreshToken":"…"}}'

# OneDrive：config.folderPath 指定目标路径
$BIN --add-connector '{"id":"onedrive","name":"OneDrive","type":"onedrive_api",
  "config":{"folderPath":"NovPool/技术"},
  "oauth":{"provider":"microsoft","clientID":"…","clientSecret":"…","refreshToken":"…","tenant":"common"}}'

$BIN --list-connectors   # 查看连接器与同步队列
$BIN --sync-now          # 手动跑一轮（排障用）
```

登记时会立刻做一次鉴权校验；离线环境下云端校验会失败，但配置仍会保留。

### 跨云级联怎么工作

路由决策给出的目标会被自动排序：**需要原始文件的连接器（网盘 / 本地挂载）排在前，结构化连接器（Notion）排在后**，
并串成依赖链。第一个任务成功后，它的云端链接会被注入下一个任务的 `upstreamAssetURL`，
Notion 那边既写进 URL 属性、也在正文里留一条可点击的「云端文件」段落。
任一前置任务永久失败时，下游会带着「前置任务失败：…」的原因一并终止，不会留下永远等待的僵尸任务。

## 与白皮书的偏差（及原因）

1. **存储层用系统 `libsqlite3` 取代 `GRDB.swift`**。开发环境完全离线（GitHub 域名无法解析），
   SPM 无法拉取任何依赖。`NovPoolStorage` 用 actor 封装轻量 SQLite 连接，实现与白皮书 §4.2
   一致的 Schema、FTS5 外部内容表与触发器同步策略；上层 `KnowledgeRepository` 调用形态与 GRDB
   一致，联网后可直接替换驱动而不改动业务代码。
2. **全局快捷键未接 `KeyboardShortcuts`**。Phase 4 的检索面板计划改用系统 Carbon
   `RegisterEventHotKey`，避免引入第三方依赖；`Sparkle` 自动更新同理暂缓。
3. **`com.apple.security.app-sandbox` 未开启**。Entitlements 保留了白皮书 §3.6 要求的四项权限，
   但未启用沙盒：跨应用 `AXUIElement` 读取（Firefox 地址栏）与 AppleScript 自动化在非沙盒模型下
   才可用。若后续要分发/公证，需要切到沙盒并放弃 AX 降级路径——这是 Phase 4 的打包决策。
4. **FTS5 trigram 无法命中少于 3 个字符的查询**。这是分词器本身的限制（中文两字词如「摘要」
   「知识」会漏检）。`KnowledgeRepository.searchFullText` 对 < 3 字符查询自动降级为 `LIKE`
   子串扫描，并已用测试固定该行为。
5. **网页正文提取（Readability/Turndown）与 OCR 尚未接入**（Phase 2）。`webLink` 类型当前只记录
   URL 与页面标题，`richHTML` 先以纯文本入库，Phase 2 换成 JavaScriptCore 转换后的 Markdown。
6. **路由结果目前只记录、不下发**。`IngestionOrchestrator` 会算出目标连接器并由悬浮窗提示，
   真正的推送与跨云级联由 Phase 3 的 `OutboxSyncWorker` 执行。
7. **未内嵌 Readability.js / Turndown.js**。白皮书规划用 JavaScriptCore 跑这两个脚本，但离线环境
   无法取得它们，且直接内置第三方脚本还牵涉许可问题。改用等价的原生 Swift 实现
   （`HTMLExtractor` + `MarkdownRenderer`），并保留 `ArticleExtracting` 协议作为接入点：
   以后把官方脚本 vendored 进 Bundle 后，实现一个新的 JS 引擎替换即可，流水线无需改动。
8. **`NLEmbedding` 句向量在本机返回 `nil`**。该接口依赖系统语言资源，资源缺失时不可用；
   因此向量回退链的最后一级可能落空，条目仍会保留摘要与标签（已用测试固定该降级行为）。
9. **AI 默认指向本地 Ollama（`127.0.0.1:11434`）**。没装/没启动时调用会立即失败，增强静默跳过，
   不影响入库。可用 `defaults write com.novpool.app novpool.openai.baseURL ...` 等键切到
   OpenAI 兼容接口；Phase 4 会把设置面板接到这些键上。
10. **PDF 优先使用自带文字层**。这不是偏差而是对「扫描版才 OCR」的工程化落地：
   数字版 PDF 走文字层是毫秒级且比 OCR 更准，只有文字层不足 40 字符时才栅格化 + OCR。
11. **检索面板没做 QuickLook（空格预览），改成面板内右侧详情栏**。`QLPreviewPanel` 需要一个
   响应链上下文，在无边框浮窗里接起来很脆；面板内直接展示正文对知识库场景更实用，也更好测。
12. **没有绑定 ⌘C 复制**。AppKit 文本框会先消费 ⌘C，绑一个「有时不生效」的快捷键比不绑更糟；
    改成面板内明确的「复制」按钮，行为 100% 确定。
13. **语义命中有前提**：库里得有 `embeddingBlob`。这需要 AI 增强开启且 embedding 通道可用
    （Ollama `bge-m3`，或 `NLEmbedding` 兜底）。一条都没有时，面板仍可正常按关键词检索，
    所有结果标注为「关键词」。
14. **快捷键被占用时的行为**：`RegisterEventHotKey` 失败不会崩，只是不注册；面板仍可从菜单栏打开，
    菜单栏首行会提示「快捷键被占用，请从菜单打开搜索」。想换组合就用
    `defaults write com.novpool.app novpool.hotkey -string "cmd+shift+k"`。

## 已知环境坑

### 视图里的主 actor 约定（踩过坑）

SwiftUI 的结果构建器闭包（`ForEach` 的 content、`ZStack` 的 content、`onAppear` / `onChange`）
以及 AppKit 的回调（`hitTest`、`NSDraggingDestination`、NSTextField delegate）签名都是**非隔离**的。
在这些闭包里直接读 `@MainActor @Observable` 模型，编译器会插入运行时"当前执行器"检查
（`swift_task_isCurrentExecutor…`），而该函数在真实 app 环境里出现过稳定 `EXC_BAD_ACCESS`
（`swift_getObjectType`，两次崩溃地址完全相同）。同类触发点还包括：

* 传给 `map` / `filter` / `sorted` / `compactMap` 的闭包里读 `@MainActor` 状态或 actor 隔离属性；
* `MainActor.assumeIsolated` —— **它自己就会调用那个函数**，因此本项目一律不用；
* SwiftUI 的手势 / 按钮 action 闭包里直接调用模型方法。

统一约定：

* 视图只消费**纯值快照**（`PanelSnapshot` / `SearchSnapshot`），闭包里不出现模型访问；
* 需要在闭包里回调模型时，二选一：把回调参数声明成 `@MainActor`（闭包体内即为静态主 actor 隔离），
  或 `Task { @MainActor in … }` 跳一次；
* 视图与桥接层的回调类型声明成 `@MainActor`（`DragCaptureBridge`）；
* 命中区域这类状态由控制器主动推送，视图不回调。

**可机械验证**：编译后统计运行时代码里是否还引用那个检查函数，应为 0
（这正是定位本次崩溃的手段）：

```bash
for f in $(find /tmp/novpool-build/out -name "*.o" -path "*Release*"); do
  n=$(nm -u "$f" | grep -c swift_task_isCurrentExecutor)
  [ "$n" != 0 ] && echo "$n  $(basename $f)"
done   # 无输出即为干净

nm -u build/NovPool.app/Contents/MacOS/NovPool | grep -c swift_task_isCurrentExecutor   # 期望 0
```

`ViewRenderProbeTests` 另外把两个面板在静默 / 展开 / 高亮 / 空态 / 结果态 / 失败态下各求值一遍
（debug 与 release 都跑），守住"视图能被求值"这条底线。

### 崩溃报告与符号

`scripts/build-app.sh` 会把 `NovPool.app.dSYM` 放在 app 旁边，崩溃报告因此能定位到具体行号。
如果 app 崩了：`ls -t ~/Library/Logs/DiagnosticReports | head`，再配合 `~/Library/Logs/NovPool.log`
里的启动面包屑定位到具体环节。

本仓库位于受 FileProvider 同步的目录（`~/Documents`）。构建产物会自动带上
`com.apple.FinderInfo` 等扩展属性，导致 `codesign` 报
`resource fork, Finder information, or similar detritus not allowed`。
两种规避方式任选其一：

* 构建时把产物放到同步目录之外：`swift test --scratch-path /tmp/novpool-build`；
* 或在签名前清属性：`xattr -cr <产物路径>`（`scripts/build-app.sh` 已内置该步骤）。

## 验证情况

已在本机跑通：

* `swift test`：**202 个用例 / 25 个 suite 全部通过**。
  Phase 1：粘贴板优先级、扇区几何、数据库与 FTS5（含 trigram 短查询降级）、Staging 哈希、
  溯源降级、摄取流水线、路由规则、连接器写盘、布局计算。
  Phase 2：OCR 阅读顺序与置信度过滤、PDF 文字层与栅格化、HTML→Markdown 全结构、
  正文打分与噪声剔除、字符集嗅探（GBK/BOM/meta）、抓取错误分类、AI 提示词与容错 JSON 解析、
  标签/分类/摘要归一化、Ollama 与 OpenAI 线格式、向量回退链、补齐流水线端到端回填。
  Phase 4 核心：RRF 融合语义（跨路一致性优先、k 值敏感性）、纯 FTS 检索、短查询兜底、
  语义-only 召回、两路命中去重、相似度阈值与维度不一致保护、结果装配（预览回退 OCR、
  本地文件校验、limit）、面板状态机（唤起加载最近 / 去抖检索 / 空与失败态 / 选择夹紧 /
  回车三种动作 / 复制）、布局与多屏选择、快捷键解析。
  首次启动路径：数据目录缺失时自动创建、SQLite 父目录不存在时也能建库（这两条是
  「装完启动即退」的回归用例）。
  Phase 3：发件箱入队顺序与依赖链、级联注入上游外链、前置失败级联终止、指数退避与重试上限、
  连接器未配置直接终止、观察者事件、本地挂载真实落盘端到端；Notion 的 Block 转换（标题/列表/
  待办/引用/代码/图片/行内注解/2000 字符切分/语言映射）与请求构造（鉴权头、属性映射、分批追加、
  数据库列表）；Drive 的 multipart 与 resumable 双路径；OneDrive 的直传与分片上传
  （Content-Range、320KiB 对齐）、路径穿越清洗；PKCE 推导、令牌刷新、授权地址构造。
  Phase 4 设置与 CLI：`--list-connectors` / `--add-connector` / `--remove-connector` / `--sync-now`
  在本机实际跑通（登记 → 鉴权校验 → 列出 → 同步）。
* 根包 `swift build` 产出可执行文件；`scripts/build-app.sh` 组装 `NovPool.app`（Release、
  arm64、约 1.9 MB）并通过 `codesign --sign -` + Entitlements 校验。
* `NovPool.xcodeproj` 通过 `plutil -lint` 与 `xcodebuild -list` 的工程解析阶段。

尚未验证（受当前环境限制，需在有图形会话的桌面确认）：

* 真实拖拽交互（悬浮窗、扇区高亮、松手入库、焦点不丢失）——本环境无 WindowServer 访问权限。
* 真实 Vision OCR 识别精度——沙盒内 ANE 服务不可达，`VNImageRequestHandler.perform` 返回 `nilError`；
  相关用例带 `.enabled(if:)` 条件，在你机器上会自动启用并校验识别结果。
* 真实网页抓取与真实 LLM 调用——本环境无法解析任何域名，全部走注入式替身验证协议层。
* `xcodebuild` 完整构建——它强制读写 `~/Library/Caches/org.swift.swiftpm`，被沙盒拒绝。
* Keychain 读写、安全作用域书签恢复、AXUIElement 真实读取（需要真实权限授予）。
* 云端 API 的真实往返（本环境无网络）：Notion / Drive / OneDrive 的请求构造与响应解析已用替身
  传输层验证到字节级，但真正的 OAuth 授权回调与上传没有跑过。
* 设置面板的实际外观与交互（同 GUI 限制）。

## 下一步

1. **OAuth 授权界面**：把 `ASWebAuthenticationSession` 接进设置面板（目前授权靠命令行传刷新令牌），
   并做令牌自动续期与失效提示。
2. 检索面板增强：QuickLook 空格预览、按分类/类型/时间过滤、结果高亮关键词。
3. 设置面板补齐云端连接器表单（Notion 数据库下拉、网盘目录选择），减少命令行依赖。
4. 扇区槽位自定义（目前固定四个：智能路由 / Notion / Google Drive / OneDrive）。
5. 可选：`WKWebView` 动态渲染引擎（SPA 页面）、官方 Readability.js/Turndown.js 的 JS 引擎接入、MCP 连接器。
