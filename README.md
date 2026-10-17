# DayPilot

![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)
![Build](https://img.shields.io/badge/Build-passing-brightgreen.svg)

![DayPilot Banner](https://raw.githubusercontent.com/Ravinder82/DayPilot/master/dist/previews/banner.png)

**Native macOS app: a windowed library and editor that turns an unstructured workday into a dynamic, evidence-grounded Day Brief.**

Press **Start**, forget it exists. Press **Stop & Debrief**, get an honest chief-of-staff readout of what actually shipped, what ideas you nearly lost, and what to do first tomorrow morning. The main window holds the session library and the report editor.

---

## ✨ Features

| Area | Highlights |
|------|------------|
| **🗂 Session Library** | Live session row with pulsing timer • Archived sessions with event/breadcrumb counts • Context menu: Duplicate, Delete, Reveal in Finder |
| **📝 Report Editor** | Rendered Markdown by default • Source edit mode (⌘⇧U) with debounced auto-save • Code blocks with copy button • Tables, quotes, lists • Export: Markdown, HTML, PDF, Plain Text |
| **⏱ Session Console** | One play/pause toggle + Stop & Debrief in the top bar • A plain stopwatch counts the session upward, holds on pause, resets on stop • Pause never writes a brief — only Stop does |
| **📋 Day Brief** | Chief-of-staff debrief written from a deterministic evidence pack • BLUF opener, dynamic sections, artifacts verified against the payload • Slop filter: no emoji, canned phrases, or fabricated paths ever reach the report |
| **🧠 Memory (File Manager)** | Security-scoped bookmarks — no Full Disk Access needed • Recursive indexing with SHA-256 dedup • Search by name/path/summary • Filter by folder & file type (code, images, PDF, video…) • Clean missing files & duplicates • Per-file context menu |
| **🤖 AI Providers** | Live `/models` fetch from any OpenAI-compatible endpoint • Free/Paid/Unpriced badges • Curated fallbacks for Google, OpenRouter, Groq, NVIDIA, DeepSeek • Custom endpoints (add/edit/remove) • Test Connection before saving key |
| **🔐 Keychain Storage** | API keys in macOS Keychain (`service: com.daypilot.apikeys`) • Test Connection uses typed key before saving • Remove individual or all keys |
| **💾 Persistence** | SQLite (`~/Library/Application Support/DayPilot/DayPilot.sqlite`) • Reports as Markdown (`~/…/Reports/YYYY-MM-DD_<sessionId>.md`) • User memory profile (`user_memory.json`) • Model catalogue cache (`model_catalog.json`) |
| **🪟 Native macOS** | Windowed app — Dock icon, Launchpad, Spotlight, Cmd+Tab • Settings window (⌘,) • Full dark/light appearance • Signed with Apple Development identity (TCC grants survive rebuilds) |

---

## 🏗 Architecture

```
DayPilotApp (@main)
├── AppDelegate          # NSApplicationDelegate — quit handling, snapshot harness
├── AppModel (@MainActor ObservableObject)
│   ├── SessionCoordinator    # Capture → OCR → SQLite → Synthesis → Archive → Zero-Trace purge
│   ├── SessionStore          # SQLite: session_events, sessions
│   ├── UserMemoryStore       # JSON profile + rules of thumb
│   ├── ReportLibrary         # Markdown files + Trash
│   ├── FileManagerStore      # Bookmarks + file index (UserDefaults)
│   ├── ModelCatalog          # Live /models + curated fallback + cache
│   └── Settings (AppSettings)# UserDefaults preferences
├── Capture Engine
│   ├── ScreenCaptureEngine   # SCShareableContent + SCStream (15s interval)
│   ├── VisionTextExtractor   # VNRecognizeTextRequest (ANE)
│   └── WindowManager         # Accessibility API for window titles
├── Synthesis
│   ├── APIClient             # OpenAI-compatible, model override, 401/403/429 hints
│   ├── PromptBuilder         # Chief-of-staff prompt + deterministic evidence pack
│   ├── BriefSanitizer        # Slop filter, artifact verification, title canonicalisation
│   └── ReportArchiver        # Markdown + provenance + rules of thumb
└── UI (SwiftUI)
    ├── MainWindowView        # Top bar: Library | Memory + focus console
    │   ├── SessionSidebarView
    │   ├── ReportEditorView
    │   └── FileManagerView
    └── SettingsView          # Provider, model, permissions, developer tools
```

---

## 🚀 Quick Start

```bash
# 1. Clone & build
git clone https://github.com/Ravinder82/DayPilot.git
cd DayPilot
make setup      # validates toolchain
make build      # release build (~30s)

# 2. Install to /Applications (signed, Dock + Launchpad)
make install

# 3. Launch from Launchpad / Spotlight
# 4. Grant Screen Recording — DayPilot's own sheet deep-links to System Settings
# 5. Open Settings (⌘,) → Providers → Add your API key
# 6. Click Start in the top-bar console
```

### API Keys (choose one)

```bash
export GEMINI_API_KEY="..."        # Google AI Studio (Gemini 2.0 Flash — free)
export OPENROUTER_API_KEY="..."   # OpenRouter (459 models, 19 free)
export GROQ_API_KEY="..."         # Groq (4 free models, instant)
export NVIDIA_API_KEY="..."       # NVIDIA NIM (80 models)
export DEEPSEEK_API_KEY="..."     # DeepSeek (paid)
```

The first provider with a valid key becomes active automatically (priority: Google → OpenRouter → Groq → NVIDIA → DeepSeek).

---

## 🛠 Commands

```bash
make build            # Compile release binary
make run              # Package + open dist/DayPilot.app
make install          # Package + copy to /Applications
make package          # Build, sign, verify dist/DayPilot.app
make snapshots        # Capture app windows (light+dark) to dist/previews/
make selftest         # System health check (exits 0/1)
make integration-test # Full pipeline: capture → synthesize → archive → purge
make clean            # Remove .build, .swiftpm, dist/
```

### Launch Flags

| Flag | Purpose |
|------|---------|
| `--selftest` | Run health check & exit |
| `--brief-preview` | Offline brief pipeline check — no network, no Keychain |
| `--stress-test` | 200-event simulation through Laya + synthesis + purge |
| `--integration-test` | Full synthesis run (sandboxed) |
| `--test-connection <provider>` | Test a key via `DAYPILOT_TEST_KEY` env |
| `--list-models <provider>` | Print live model catalogue |
| `--no-capture` | Skip launch capture cycle |
| `--preview-fixtures` | Show sample content (for screenshots) |
| `--snapshot-windows <dir>` | Capture own windows to PNG |
| `--snapshot-appearance light\|dark` | Appearance for snapshots |

---

## 🧩 Extending

### Add a Custom Provider
1. Settings → Providers → **Add Custom Provider…**
2. Name: `Together AI` • Base URL: `https://api.together.xyz/v1` • Your API key
3. Click **Refresh List** → pick a model (e.g. `meta-llama/Llama-3-70b`)
4. Done — works like any built-in provider

### Report Templates
```swift
// In ReportLibrary.swift — add to ReportTemplate enum
case weeklyReview
    var markdown: String {
        "# Weekly Review — \(date)\n\n## Shipped\n\n## Learned\n\n## Next Week\n"
    }
```

### File Manager Cleanup
```swift
// In AppModel or a scheduled task
fileManager.cleanMissingFiles()   // Removes index entries for deleted files
fileManager.cleanDuplicates()     // Keeps one copy per SHA-256 hash
```

---

## 🔒 Privacy & Permissions

| Permission | Why | Grant Via |
|------------|-----|-----------|
| **Screen Recording** | Capture window frames for OCR | System Settings → Privacy & Security → Screen Recording |
| **Accessibility** | Read window titles / app names | System Settings → Privacy & Security → Accessibility |
| **Microphone** | Not used — DayPilot records nothing audible | N/A |

**No raw video leaves your Mac.** Frames → Vision (ANE) → text delta → SQLite. Sensitive apps (1Password, Keychain, Messages, FaceTime, banking URLs) are blocked before capture.

**Zero-Trace:** after a Day Brief is written, every raw OCR row is deleted from SQLite and the database is vacuumed. The final Markdown report is the only thing that survives a session.

---

## 📦 Distribution

### Developer Install (this repo)
```bash
make install  # → /Applications/DayPilot.app (signed, Team ID: P8Z36BQ85J)
```

### Release Build (for sharing)
```bash
# Requires Developer ID Application certificate
make package  # → dist/DayPilot.app (verified, notarization-ready)
```

**TCC grants survive rebuilds** because the designated requirement is certificate-based (`identifier "com.daypilot.app" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"`), not cdhash-based.

---

## 🤝 Contributing

1. Fork → branch → PR
2. `make selftest` must pass
3. Follow Swift 6 strict concurrency (`@MainActor`, `Sendable`, actors)
4. No external SwiftPM dependencies (system SQLite, frameworks only)

---

## 📄 License

MIT — see [LICENSE](LICENSE).

---

## 👤 Author

**Ravinder Poonia**  
🔗 [github.com/Ravinder82](https://github.com/Ravinder82)  
📧 [Open an issue](https://github.com/Ravinder82/DayPilot/issues) for bugs or feature requests.

---

*Built with Swift 6, SwiftUI, ScreenCaptureKit, Vision, and a lot of ☕.*