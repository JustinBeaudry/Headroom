import SwiftUI
import AppKit
import HeadroomCore

public struct PopoverView: View {
    @Environment(\.openSettings) private var openSettingsScene
    @Bindable var viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    private func openSettingsWindow(for provider: ProviderID? = nil) {
        if let provider {
            viewModel.selectedSettingsProvider = provider
        }
        NSApp.activate(ignoringOtherApps: true)
        openSettingsScene()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            summaryStrip
            Divider()
                .opacity(0.5)

            // Explicit non-collapsing scrollable body:
            // macOS MenuBarExtra(.window) collapses bare `ScrollView { LazyVStack }` to 0pt
            // unless given a concrete height bound or regular VStack content height.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 9) {
                    if !viewModel.hasCompletedInitialLoad {
                        SkeletonCardView()
                        SkeletonCardView()
                        SkeletonCardView()
                    } else if viewModel.state.sharedPools.isEmpty && viewModel.activeSnapshots.isEmpty && viewModel.unconfiguredSnapshots.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.state.sharedPools) { pool in
                            SharedPoolCardView(pool: pool, privacyMode: viewModel.privacyMode)
                        }

                        ForEach(viewModel.activeSnapshots) { snapshot in
                            ProviderCardView(
                                snapshot: snapshot,
                                privacyMode: viewModel.privacyMode,
                                showAccountLabel: viewModel.hasMultipleAccounts,
                                onReauth: { viewModel.openReauth(for: snapshot.provider) },
                                onConfigure: { openSettingsWindow(for: snapshot.provider) },
                                onRefresh: { Task { await viewModel.refresh(force: true) } }
                            )
                        }

                        if !viewModel.unconfiguredSnapshots.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("AVAILABLE INTEGRATIONS")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.6)
                                    .padding(.horizontal, 2)
                                    .padding(.top, 4)

                                ForEach(viewModel.unconfiguredSnapshots) { snapshot in
                                    CompactUnconfiguredRow(
                                        snapshot: snapshot,
                                        onConnect: { openSettingsWindow(for: snapshot.provider) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: computedScrollHeight)

            Divider()
                .opacity(0.5)
            footer
        }
        .frame(width: HeadroomTheme.popoverWidth)
    }

    /// Computes a crisp, exact height for the scroll viewport so MenuBarExtra never collapses to 0pt
    /// and never leaves awkward dead whitespace.
    private var computedScrollHeight: CGFloat {
        if !viewModel.hasCompletedInitialLoad {
            return 280
        }
        if viewModel.state.sharedPools.isEmpty && viewModel.activeSnapshots.isEmpty && viewModel.unconfiguredSnapshots.isEmpty {
            return 210
        }
        var estimated: CGFloat = 24 // top + bottom padding
        for pool in viewModel.state.sharedPools {
            estimated += 108 + CGFloat(pool.supplementaryWindows.count) * 52 + 9
        }
        for snap in viewModel.activeSnapshots {
            let winHeight = snap.windows.isEmpty ? 64 : CGFloat(snap.windows.count) * 52
            estimated += 46 + winHeight + 9
        }
        if !viewModel.unconfiguredSnapshots.isEmpty {
            estimated += 24 + CGFloat(viewModel.unconfiguredSnapshots.count) * 44
        }
        return min(max(estimated, 200), 500)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Headroom")
                        .font(.system(size: 14, weight: .semibold))
                    if viewModel.demoMode {
                        Text("DEMO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HeadroomTheme.sharedPool)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(HeadroomTheme.sharedPool.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(viewModel.isRefreshing ? HeadroomTheme.sharedPool : HeadroomTheme.reserve)
                        .frame(width: 6, height: 6)
                    Text(viewModel.relativeUpdatedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help(viewModel.pollingTooltip)
            }

            Spacer()

            HStack(spacing: 2) {
                ToolbarIconButton(
                    systemName: viewModel.privacyMode ? "eye.slash.fill" : "eye",
                    helpText: viewModel.privacyMode ? "Show usage values" : "Hide during screen share",
                    isActive: viewModel.privacyMode
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.privacyMode.toggle()
                    }
                }

                ToolbarIconButton(
                    systemName: viewModel.config.menuBarDisplayMode == .mostUrgent
                        ? "chart.bar.fill"
                        : "gauge.with.dots.needle.67percent",
                    helpText: viewModel.config.menuBarDisplayMode == .mostUrgent
                        ? "Switch menu bar to Mini Bars"
                        : "Switch menu bar to Most Urgent"
                ) {
                    viewModel.toggleDisplayMode()
                }

                ToolbarIconButton(
                    systemName: "arrow.clockwise",
                    helpText: "Refresh all providers now",
                    isSpinning: viewModel.isRefreshing,
                    disabled: viewModel.isRefreshing
                ) {
                    Task { await viewModel.refresh(force: true) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var summaryStrip: some View {
        if !viewModel.privacyMode,
           viewModel.hasCompletedInitialLoad,
           (viewModel.bestAvailableSummary != nil || viewModel.nextResetSummary != nil) {
            HStack(spacing: 10) {
                if let best = viewModel.bestAvailableSummary {
                    HStack(spacing: 4) {
                        Text("Most room:")
                            .foregroundStyle(.secondary)
                        Text("\(best.name) \(best.headroom)%")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(best.headroom > 35 ? HeadroomTheme.reserve : HeadroomTheme.onTrack)
                    }
                }

                Spacer()

                if let reset = viewModel.nextResetSummary {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(reset.label) in \(reset.countdown)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Connect a provider to see headroom")
                .font(.system(size: 13, weight: .semibold))
            Text("Headroom automatically reads local CLI sessions for Codex, Gemini, and Cursor. Add a cookie in Settings for Claude or Grok, or preview with Demo.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Preview Demo") {
                    viewModel.toggleDemoMode()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Settings") {
                    openSettingsWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(viewModel.demoMode ? "Exit Demo" : "Demo Mode") {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewModel.toggleDemoMode()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(viewModel.demoMode ? HeadroomTheme.sharedPool : .secondary)

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
