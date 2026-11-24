# Headroom

Native macOS AI quota & burn-rate telemetry (**Swift 6 + SwiftUI `MenuBarExtra` + Swift CLI**).

Headroom tracks what's **left** — and whether your current burn rate leaves you **in reserve** or **in deficit** before reset — across **Claude**, **Codex**, **Gemini**, **Grok**, and **Cursor** with zero WebView overhead and zero raw password storage.

---

## Architecture

Headroom decouples its local data engine (`HeadroomCore`) from both the CLI (`headroom`) and the native macOS menu bar frontend (`HeadroomApp`):

```
Sources/
├── HeadroomCore/   # Normalized schema, Pace math, Keychain/JSON stores, 5 adapters, PoolDeduplicator, AdaptivePoller, AlertEvaluator
├── headroom/       # CLI (`headroom status --json`, `poll`, `pools`, `costs`, `auth`, `config`, `daemon`, `doctor`)
└── HeadroomApp/    # Native SwiftUI MenuBarExtra app + UNUserNotificationCenter alerts + Settings
```

### Core Capabilities

- **Zero-Password / Session-Reuse Auth:** Automatically detects local CLI OAuth caches (`~/.claude/.credentials.json` & Claude Code Keychain item, `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`, Cursor `state.vscdb`) and stores opt-in browser session cookies / API keys in the macOS Keychain.
- **Pace (Burn Rate) Engine:** Compares `% of quota used` against `% of reset window elapsed` to classify every window as `reserve`, `on_track`, or `burning_fast`, plus projected exhaustion time before reset.
- **Unified X Subscription Deduplication:** Detects Cursor `isUnified` / `SAND_BILLING_BRAND_GROK` so X Subscription accounts never falsely read legacy monthly fields as 100% exhausted, and links Cursor + Grok into one unified weekly pool card while keeping Cursor's 3rd-party API cap and Grok's xAI prepaid credits distinct.
- **Gemini Lane Toggling:** Switch cleanly between `auto`, `cli` (Gemini CLI daily requests/logs), `gcp_quota` (`cloudaicompanion.googleapis.com`), or `api_key` budget tracking.
- **Adaptive Polling & Fault Isolation:** Polls every 90s when local CLI/HID activity is detected, backs off to 20m when idle, and isolates per-provider failures with exponential backoff + stale telemetry preservation.
- **Menu Bar App (`HeadroomApp`):** Switch between **Most Urgent Limit** and **Mini Stacked Bars**, toggle one-click **Privacy Mode** ("Hide during screen share"), inspect visual dual-track pace bars, and receive native macOS alerts for low headroom (<= 20%), projected exhaustion, window resets, and expired cookies.

---

## Quick Start

### 1. Build & Test

```bash
swift test
swift build
```

### 2. Preview Immediately with Demo Mode

```bash
# Formatted terminal view (shows all 5 providers + unified X Subscription pool)
swift run headroom status --demo

# Normalized JSON output for scripts / shell prompts / status lines
swift run headroom status --demo --json
```

### 3. Inspect Discovered Local Credentials & CLI Costs

```bash
swift run headroom doctor
swift run headroom auth status
swift run headroom costs --days 7
```

### 4. Store an Opt-In Session Cookie or API Key in macOS Keychain

```bash
swift run headroom auth set claude --kind cookie
swift run headroom auth set grok --kind cookie
swift run headroom auth set cursor --kind cookie
```

### 5. Launch the Native Menu Bar App

```bash
# Quick launch from SwiftPM
swift run HeadroomApp

# Or build a standalone .app bundle (enables native macOS Notification Center alerts)
chmod +x scripts/bundle-app.sh
./scripts/bundle-app.sh
open dist/Headroom.app
```

---

## CLI Reference

| Command | Description |
| --- | --- |
| `headroom status [--json] [--provider <name>] [--account <label>] [--cached] [--demo]` | Display normalized usage, headroom %, pace status, and reset countdowns |
| `headroom poll [--provider <name>] [--json]` | Force an immediate live refresh across providers |
| `headroom pools [--json] [--demo]` | Inspect linked shared pools (e.g., X Subscription Cursor + Grok) |
| `headroom costs [--days <n>] [--json]` | Estimate local CLI token & USD spend from Claude/Codex/Gemini JSONL logs |
| `headroom auth status \| set \| clear` | Inspect discovered sessions or manage Keychain cookies/tokens/API keys |
| `headroom config show \| init \| add-account \| set-gemini-lane` | Manage multi-account (`work`/`personal`) config and Gemini lane |
| `headroom daemon [--once]` | Run the adaptive background poller headless |
| `headroom doctor` | Check local cache paths and CLI/editor integration probes |
