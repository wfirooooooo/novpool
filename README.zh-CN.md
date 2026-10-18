# NovPool

**[English](README.md)** | **[中文](README.zh-CN.md)**

**网上看到想留的东西，拖进小工具，以后能查、能理、能总结。**

NovPool 是 macOS 菜单栏 / 悬浮图标小工具。把网页、文件、图片、视频或文字拖到桌面图标，即可写入**本机优先**的知识库；可选 AI 增强与云同步。

| | |
| :--- | :--- |
| 平台 | macOS（Apple Silicon / Intel） |
| 界面语言 | 默认 English，可在设置中切换为中文 |
| 数据 | 本机 SQLite + 暂存文件（Application Support） |

---

## 功能

- **捕获** — 将文件、浏览器标签/链接、图片或文字拖到悬浮图标；悬停展开扇区，可快速指定目标。
- **本机知识库** — 默认先落盘（SQLite + FTS5）；云推送可选，默认关闭。
- **主题分类** — 分类描述*内容讲什么*（技术、产品、生活…），不是文件类型。资源形态（网页、图片、PDF…）以固定标签展示。
- **后台补齐** — Vision OCR、网页正文提取；配置 AI 后可生成摘要 / 主题 / 标签 / 向量。
- **检索** — 全局快捷键（默认 `⇧⌘Space`）：全文（BM25）+ 可选语义检索，RRF 融合。面板可调大小与左右栏宽。
- **AI 后端（互斥）** — Ollama、OpenAI 兼容接口，或本机 llama.cpp（`llama-server` Base URL）。同一时间只能开一个。
- **可选云端** — 本机挂载目录（Drive / OneDrive / Obsidian / iCloud）与 API 连接器（Notion / Drive / OneDrive），事务性发件箱同步。

---

## 安装与运行

```bash
# 单元测试
./scripts/test.sh

# 组装可双击运行的 app（Release，ad-hoc 签名 + 启动自检）
./scripts/build-app.sh
./scripts/build-app.sh --run

# 无界面端到端自检（数据目录 → 建库 → 暂存 → 入库 → 检索）
./build/NovPool.app/Contents/MacOS/NovPool --selftest

# 或用 Xcode 打开
open NovPool.xcodeproj
```

受限 / CI 环境（`~/Library` 不可写）可追加：  
`--disable-sandbox --scratch-path /tmp/novpool-build`，必要时设置 `NOVPOOL_SKIP_DSYM=1`。

| 变量 | 含义 |
| :--- | :--- |
| `NOVPOOL_APP_DIR` | 产物输出目录（默认 `build/`） |
| `NOVPOOL_DATA_DIR` | 数据根目录（默认 `~/Library/Application Support/NovPool`） |
| `NOVPOOL_SKIP_SELFTEST=1` | 跳过构建后的启动自检 |

---

## 使用方法

### 日常捕获

1. 启动 NovPool — **没有 Dock 图标**（`LSUIElement`）。看**菜单栏图标**和桌面**悬浮投放图标**（默认右下角）。
2. 把文件、图片、浏览器标签或文字拖到悬浮图标上。
3. 悬停时扇区展开；松在扇区可强制目标，松在中心走智能 / 本机路由。
4. 状态提示：*已收录* / *已存在*。OCR / 正文 / AI 在后台补齐。

**浏览器标签：** 请在 **系统设置 → 隐私与安全性 → 自动化** 中允许 NovPool 控制浏览器，以便读取当前标签 URL/标题。没有权限时，标签拖拽可能退回到较弱的粘贴板数据。

### 搜索

- 菜单栏 → **搜索知识库…**，或按全局快捷键（默认 **⇧⌘Space**）。
- 输入即搜；空查询列出最近条目。
- ↑↓ 选择 · ↩ 打开（浏览器 / 访达中显示 / 复制文字）· **复制** 导出 Markdown · esc 收起。
- 拖面板边缘调整大小；拖分割条调整左右栏宽。
- 详情区可编辑**主题分类**、标签、置顶与收藏。

### 设置（菜单栏 → 设置…）

| 标签 | 配置内容 |
| :--- | :--- |
| **本机知识库** | 本机优先说明；主题分类树 |
| **检索与 AI** | 快捷键；启用 AI；选择**唯一**后端（Ollama / OpenAI 兼容 / 本机 llama.cpp）；模型与 Base URL；可选 llama-server 启动命令 |
| **路由** | 规则 JSON + 默认连接器 |
| **云端（可选）** | 本机归档目录；开启同步；立即跑一轮 |
| **维护** | 重置悬浮窗位置；打开数据/日志目录；清理旧同步任务 |
| **界面语言** | English 或 中文（设置与菜单立即生效） |

### 本机 llama.cpp

1. 在 **检索与 AI** 中选择 **本机 llama.cpp**。
2. 填写 **Base URL**（默认 `http://127.0.0.1:8080/v1`），用法与 Ollama 相同。
3. 自行启动 `llama-server`（可复制提示命令），或配置二进制 / `.gguf` 后由 NovPool 代启。
4. 点 **测试连接** 验证接口。

### 可选云端连接器（命令行）

图形界面支持**本机归档目录**（安全作用域书签）。API 类连接器可用命令行登记（凭据进钥匙串，不落库）：

```bash
BIN=./build/NovPool.app/Contents/MacOS/NovPool

$BIN --add-connector '{"id":"notion","name":"Notion","type":"notion",
  "config":{"databaseID":"…","titleProperty":"Name","tagsProperty":"Tags",
  "categoryProperty":"Category","summaryProperty":"Summary"},
  "token":"ntn_…"}'

$BIN --list-connectors
$BIN --sync-now
```

---

## 启动排查

若脚本跑完却看不到界面：

```bash
./build/NovPool.app/Contents/MacOS/NovPool --selftest
tail -40 ~/Library/Logs/NovPool.log
```

启动失败会写日志并弹出提示。自检覆盖数据目录可写、SQLite 迁移、暂存写入、入库与全文检索。

悬浮图标可任意拖动，位置会记住。菜单中的 **重置悬浮窗位置** 可恢复默认角落。

---

## 目录结构

```text
NovPool.xcodeproj            # App 工程与共享 Scheme
NovPoolApp/                  # 入口、设置、Info.plist、Entitlements
Packages/NovPoolKit/         # Swift 6 包（严格并发）
  Sources/NovPoolCore/         领域模型、路由、几何
  Sources/NovPoolStorage/      SQLite（WAL+FTS5）、暂存、Keychain、向量
  Sources/NovPoolSystemBridge/ 粘贴板、OCR、提取、AI、摄取
  Sources/NovPoolConnectors/   云盘挂载、Notion/Drive/OneDrive、发件箱
  Sources/NovPoolUI/           悬浮窗、检索面板、快捷键
  Tests/NovPoolKitTests/
scripts/                     # test.sh、build-app.sh
```

---

## 架构示意

```text
拖拽 / 全局兜底
  → PasteboardResolver
  → StagingStore（原子写入 + SHA256 去重）
  → BrowserContextExtractor（短超时）
  → knowledge_items  ← 界面提示「已收录」
       → EnrichmentPipeline（后台）
            OCR / PDF 文字 / 网页正文 / AI 摘要+标签+向量
```

检索：**FTS5（BM25）+ vDSP 余弦相似度**，经 **RRF** 融合。无向量时自动退化为纯全文检索。
