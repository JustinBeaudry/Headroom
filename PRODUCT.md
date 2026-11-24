# Headroom — Product Context

## Product Purpose
Headroom is a native macOS menu bar and CLI telemetry utility that answers one question in under a second: **"Where is my AI quota headroom right now, and am I going to hit the wall before reset?"**

It tracks remaining allowance, reset countdowns, and burn-rate pacing across **Claude**, **Codex**, **Gemini**, **Grok**, and **Cursor** (including unified X Subscription pool deduplication) without duplicate polling, WebView bloat, or password storage.

## Register
`product`

Design serves the task. Familiarity, calm precision, tabular alignment, and immediate scannability matter more than decorative flourishes.

## Users
- **Daily AI-assisted software engineers** running multiple coding tools simultaneously (Claude Code, Codex CLI, Cursor, Gemini CLI, Grok) across macOS terminals and editors.
- **Usage-conscious power users** who switch models proactively when one provider's 5-hour or weekly window runs low or burns ahead of schedule.

## Core User Jobs
1. **Glance at the menu bar** to spot the tightest live quota or scan mini headroom meters without breaking flow.
2. **Open the usage dropdown** to see every active provider's exact remaining headroom, pace status (In Reserve / On Track / Burning Fast), and reset countdown in under 1 second.
3. **Decide which tool to use next** by seeing which providers still have ample headroom and when constrained pools reset.
4. **Fix expired sessions in one click** without hunting through config files or terminal commands.

## Tone & Voice
- Calm, precise, aviation/studio instrumentation clarity.
- Short, factual labels ("36% left", "Resets in 3h 24m", "Updated just now").
- Zero marketing fluff, zero developer debug strings ("Idle poll every 1200s") in primary surfaces, no em dashes.

## Anti-References
- Cluttered crypto/SRE dashboards with neon glow on pure black and 6-box KPI walls.
- Alarmist false-red alerts for unconfigured or estimated local-only fallbacks.
- Generic Electron/WebView popovers that ignore macOS vibrancy, typography, and native controls.
