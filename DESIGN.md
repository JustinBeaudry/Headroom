# Headroom — Design System

## Physical Scene & Theme
A software engineer glances at the top-right macOS menu bar on a Studio Display or MacBook Pro while coding in an editor and terminal, in either dark or light macOS appearance. The popover must adapt seamlessly to macOS system appearance (vibrancy-friendly tinted neutrals, never raw `#000000` or `#FFFFFF`), matching the calm precision of native macOS utilities like Raycast, Linear, and CleanShot X.

## Color Strategy
**Restrained (Product Default)** with semantic state accents only:
- **Surfaces:** Layered system-adaptive translucent surfaces with cool-slate tint (`primary.opacity(0.045)` cards, `primary.opacity(0.075)` hover lift, hairline `primary.opacity(0.09)` borders).
- **Semantic Status Roles:**
  - **Healthy / Reserve:** Emerald (`#10B981` / macOS tuned mint-green)
  - **Caution / On Track:** Amber (`#F59E0B`)
  - **Urgent / Burning Fast / Exhausted:** Coral Red (`#EF4444`)
  - **Shared Pool Link:** Electric Cyan/Blue (`#0EA5E9`)
  - **Muted / Stale / Unconfigured:** Slate neutral secondary

## Typography
- **Family:** Native Apple SF Pro (`.system`) for UI labels + SF Mono / `.monospacedDigit()` for all percentages, countdowns, and dollar figures so values align cleanly vertically and never jitter on refresh.
- **Scale (Tight Product Ratio):**
  - Header title: `14pt semibold`
  - Provider title: `13pt semibold`
  - Hero headroom figure: `14pt semibold monospacedDigit`
  - Window label: `11.5pt medium`
  - Metadata / countdown / pace tag: `10.5pt regular/medium`

## Core Component Patterns
- **Dual-Track Headroom Meter:** 6pt rounded track showing quota used filling left-to-right toward the cap, overlaid with a crisp 2pt vertical elapsed-time pace tick so reserve vs. deficit is legible at a glance without reading prose.
- **Expandable Provider Rows:** Default view shows the provider name, status, primary headroom %, meter, pace label, and reset countdown. Clicking expands secondary telemetry (burn multiplier, source, local spend, quick actions).
- **Compact Unconfigured Section:** Unconfigured providers collapse into tight single-line setup rows below active providers with one-click deep link to Settings.
- **Motion:** Crisp 150ms–200ms `easeOut` state transitions only (hover highlights, disclosure expansion, refresh spin). Zero decorative entrance choreography.
