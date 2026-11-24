import SwiftUI
import AppKit
import HeadroomCore

public struct PopoverView: View {
    @Environment(\.openSettings) private var openSettingsScene
    @Environment(\.openWindow) private var openWindow
    @Bindable var viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    private func openSettingsWindow(for provider: ProviderID? = nil, accountLabel: String? = nil) {
        if let provider {
            viewModel.selectForSettings(provider: provider, accountLabel: accountLabel)
        }
        NSApp.activate(ignoringOtherApps: true)
        openSettingsScene()
    }

    private func openUpdateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "update-window")
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)

            if let update = viewModel.visibleBannerUpdate {
                updateBanner(for: update)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                    .opacity(0.35)
            }

            if viewModel.hasMultipleAccounts {
                accountFilterBar
                    .fixedSize(horizontal: false, vertical: true)
            }

            summaryStrip
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .opacity(0.5)

            // Scrollable middle pane pinned cleanly between fixed header & footer.
            // Using a fixed outer frame on the popover prevents macOS MenuBarExtra(.window)
            // from clipping the header/footer off-screen when content height changes.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 9) {
                    if !viewModel.hasCompletedInitialLoad {
                        SkeletonCardView()
                        SkeletonCardView()
                        SkeletonCardView()
                    } else if viewModel.filteredSharedPools.isEmpty && viewModel.activeSnapshots.isEmpty && viewModel.unconfiguredSnapshots.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.filteredSharedPools) { pool in
                            SharedPoolCardView(
                                pool: pool,
                                privacyMode: viewModel.privacyMode,
                                showAccountLabel: viewModel.hasMultipleAccounts
                            )
                        }

                        ForEach(viewModel.activeSnapshots) { snapshot in
                            ProviderCardView(
                                snapshot: snapshot,
                                privacyMode: viewModel.privacyMode,
                                showAccountLabel: viewModel.hasMultipleAccounts || viewModel.hasMultipleAccounts(for: snapshot.provider),
                                onReauth: { viewModel.openReauth(for: snapshot.provider) },
                                onConfigure: { openSettingsWindow(for: snapshot.provider, accountLabel: snapshot.accountLabel) },
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
                                        showAccountLabel: viewModel.hasMultipleAccounts || viewModel.hasMultipleAccounts(for: snapshot.provider),
                                        privacyMode: viewModel.privacyMode,
                                        onConnect: { openSettingsWindow(for: snapshot.provider, accountLabel: snapshot.accountLabel) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()
                .opacity(0.5)

            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: HeadroomTheme.popoverWidth, height: 540)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Headroom")
                    .font(.system(size: 14, weight: .semibold))
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
                    systemName: displayModeIcon,
                    helpText: "Menu bar style: \(viewModel.config.menuBarDisplayMode.displayName) (click to cycle)"
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
        .padding(.vertical, 10)
    }

    private var displayModeIcon: String {
        switch viewModel.config.menuBarDisplayMode {
        case .stackedMetrics: return "rectangle.grid.2x2"
        case .inlineMetrics: return "textformat.123"
        case .miniBars: return "chart.bar.fill"
        case .mostUrgent: return "gauge.with.dots.needle.67percent"
        }
    }

    private func updateBanner(for release: ReleaseInfo) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(HeadroomTheme.sharedPool)

            Text("\(release.tagName) available")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            Button("What's New") {
                openUpdateWindow()
            }
            .buttonStyle(.borderedProminent)
            .tint(HeadroomTheme.sharedPool)
            .controlSize(.mini)

            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    viewModel.dismissUpdateBanner()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss until next check")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(HeadroomTheme.sharedPool.opacity(0.11))
    }

    private var accountFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                AccountFilterChip(
                    title: "All",
                    isSelected: viewModel.selectedAccountFilter == nil
                ) {
                    withAnimation(.easeOut(duration: 0.14)) {
                        viewModel.selectedAccountFilter = nil
                    }
                }
                ForEach(viewModel.availableAccountLabels, id: \.self) { label in
                    AccountFilterChip(
                        title: viewModel.privacyMode ? "••••" : label.capitalized,
                        isSelected: viewModel.selectedAccountFilter == label
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) {
                            viewModel.selectedAccountFilter = label
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
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
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if let reset = viewModel.nextResetSummary {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(reset.label) in \(reset.countdown)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
            Text("Headroom automatically reads local CLI sessions for Codex, Gemini, and Cursor. Add a cookie in Settings for Claude or Grok.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                openSettingsWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(viewModel.currentAppVersion.tagString)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                openSettingsWindow()
            } label: {
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

private struct AccountFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }
}
