# NovPool

**[English](README.md)** | **[中文](README.zh-CN.md)**

**Drag anything worth keeping into a tiny macOS drop zone — then search, organize, and summarize it later.**

NovPool is a menu-bar / floating-icon tool for macOS. Drop web pages, files, images, video, or text onto the desktop icon; items land in a **local-first knowledge base** with optional AI enrichment and optional cloud sync.

| | |
| :--- | :--- |
| Platform | macOS (Apple Silicon / Intel) |
| UI language | English (default) or 中文 — switch in Settings |
| Data | Local SQLite + staging files under Application Support |

---

## Features

- **Capture** — Drag files, browser tabs/links, images, or selected text onto the floating icon. Sectors expand on hover for quick routing.
- **Local library** — Everything is stored on disk first (SQLite + FTS5). Cloud push is optional and off by default.
- **Topic tagging** — Categories describe *what the content is about* (Tech, Product, Life…), not file type. Resource type (Web, Image, PDF…) is shown as a fixed display tag.
- **Background enrichment** — OCR (Vision), web article extraction, AI summary / topics / tags / embeddings when an AI backend is configured.
- **Search** — Global hotkey (default `⇧⌘Space`): hybrid full-text (BM25) + optional semantic search with RRF fusion. Resizable panel with adjustable columns.
- **AI backends (mutually exclusive)** — Ollama, OpenAI-compatible API, or local llama.cpp (`llama-server` Base URL). Only one can be active.
- **Optional cloud** — Local folder mounts (Drive / OneDrive / Obsidian / iCloud) and API connectors (Notion / Drive / OneDrive) with transactional outbox sync.

---

## Install & run

```bash
# Unit tests
./scripts/test.sh

# Build a double-clickable app (Release, ad-hoc sign + launch self-check)
./scripts/build-app.sh
./scripts/build-app.sh --run

# Headless end-to-end check (data dir → DB → staging → ingest → search)
./build/NovPool.app/Contents/MacOS/NovPool --selftest

# Or open in Xcode
open NovPool.xcodeproj
```

Restricted / CI environments (`~/Library` not writable): add  
`--disable-sandbox --scratch-path /tmp/novpool-build` and set `NOVPOOL_SKIP_DSYM=1` if needed.

| Variable | Meaning |
| :--- | :--- |
| `NOVPOOL_APP_DIR` | Build output directory (default `build/`) |
| `NOVPOOL_DATA_DIR` | Data root (default `~/Library/Application Support/NovPool`) |
| `NOVPOOL_SKIP_SELFTEST=1` | Skip post-build launch self-check |

---

## How to use

### Everyday capture

1. Launch NovPool — there is **no Dock icon** (`LSUIElement`). Look for the **menu bar icon** and the **floating drop icon** (default: lower-right).
2. Drag a file, image, browser tab, or text onto the floating icon.
3. On hover, sectors expand; drop on a sector to force a target, or on the center for smart/local routing.
4. Status toast: *Saved* / *Already exists*. Enrichment (OCR / article / AI) finishes in the background.

**Browser tabs:** allow NovPool under **System Settings → Privacy & Security → Automation** so the app can read the active tab URL/title. Without that permission, tab drops may fall back to weaker pasteboard data.

### Search

- Menu bar → **Search Knowledge…**, or press the global hotkey (default **⇧⌘Space**).
- Type to search; empty query lists recent items.
- ↑↓ select · ↩ open (browser / reveal in Finder / copy text) · **Copy** exports Markdown · esc dismisses.
- Drag panel edges to resize; drag the splitter to adjust list vs. detail width.
- In the detail pane you can edit **topic category**, tags, pin, and favorite.

### Settings (menu bar → Settings…)

| Tab | What you configure |
| :--- | :--- |
| **Library** | Local-first overview; topic category tree |
| **Search & AI** | Hotkey; enable AI; pick **one** backend (Ollama / OpenAI-compatible / local llama.cpp); models & Base URL; optional llama-server launch command |
| **Routing** | Rules JSON + default connector |
| **Cloud (optional)** | Local archive folders; enable sync; run one sync round |
| **Maintenance** | Reset drop-zone position; reveal data/log folders; prune old sync jobs |
| **Language** | English or 中文 (settings & menu update immediately) |

### Local llama.cpp

1. In **Search & AI**, select **Local llama.cpp**.
2. Set **Base URL** (default `http://127.0.0.1:8080/v1`) — same idea as Ollama.
3. Start `llama-server` yourself (copy the suggested command) or optionally let NovPool launch it after you set binary / `.gguf` paths.
4. Use **Test** to verify the endpoint.

### Optional cloud connectors (CLI)

GUI covers **local archive folders** (security-scoped bookmarks). API connectors can be registered from the CLI (credentials go to Keychain, not the DB):

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

## Troubleshooting launch

If the script finishes but you see nothing:

```bash
./build/NovPool.app/Contents/MacOS/NovPool --selftest
tail -40 ~/Library/Logs/NovPool.log
```

Startup failures write to the log and show an alert. Self-test covers data-dir writability, SQLite migrate, staging write, ingest, and full-text search.

Drag the floating icon anywhere; position is remembered. **Reset Drop Zone Position** in the menu restores the default corner.

---

## Project layout

```text
NovPool.xcodeproj            # App target + shared scheme
NovPoolApp/                  # App entry, settings, Info.plist, entitlements
Packages/NovPoolKit/         # Swift 6 package (strict concurrency)
  Sources/NovPoolCore/         Domain models, routing, geometry
  Sources/NovPoolStorage/      SQLite (WAL+FTS5), staging, Keychain, vectors
  Sources/NovPoolSystemBridge/ Pasteboard, OCR, extractors, AI, ingestion
  Sources/NovPoolConnectors/   Cloud mounts, Notion/Drive/OneDrive, outbox
  Sources/NovPoolUI/           Drop panel, search panel, hotkey
  Tests/NovPoolKitTests/
scripts/                     # test.sh, build-app.sh
```

---

## Architecture sketch

```text
Drop / global fallback
  → PasteboardResolver
  → StagingStore (atomic write + SHA256 dedupe)
  → BrowserContextExtractor (short timeout)
  → knowledge_items  ← UI: “Saved”
       → EnrichmentPipeline (background)
            OCR / PDF text / web article / AI summary+tags+embedding
```

Search: **FTS5 (BM25) + vDSP cosine similarity**, fused with **RRF**. Without embeddings, search falls back to full-text only.
