import SwiftUI
import AppKit
import HeadroomCore

public struct PopoverView: View {
    @Bindable var viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    if viewModel.state.sharedPools.isEmpty && viewModel.standaloneSnapshots.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.state.sharedPools) { pool in
                            SharedPoolCardView(pool: pool, privacyMode: viewModel.privacyMode)
                        }
                        ForEach(viewModel.standaloneSnapshots) { snapshot in
                            ProviderCardView(
                                snapshot: snapshot,
                                privacyMode: viewModel.privacyMode,
                                onReauth: { viewModel.openReauth(for: snapshot.provider) },
                                onRefresh: { Task { await viewModel.refresh(force: true) } }
                            )
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 430)

            Divider()
            footer
        }
        .frame(width: 356)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Headroom")
                        .font(.system(size: 14, weight: .bold))
                    if viewModel.demoMode {
                        Text("DEMO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.privacyMode.toggle()
            } label: {
                Image(systemName: viewModel.privacyMode ? "eye.slash.fill" : "eye")
            }
            .buttonStyle(.borderless)
            .help("Hide during screen share")

            Button {
                viewModel.toggleDisplayMode()
            } label: {
                Image(systemName: viewModel.config.menuBarDisplayMode == .mostUrgent ? "chart.bar.fill" : "gauge.with.dots.needle.67percent")
            }
            .buttonStyle(.borderless)
            .help("Toggle menu bar style (Most Urgent vs Mini Bars)")

            Button {
                Task { await viewModel.refresh(force: true) }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing)
            .help("Refresh all providers now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        if viewModel.privacyMode {
            return "Screen-share privacy enabled"
        }
        let mode = viewModel.isActivePolling ? "Active" : "Idle"
        return "\(mode) poll • every \(viewModel.nextPollSeconds)s"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No provider telemetry yet")
                .font(.headline)
            Text("Configure cookies or CLI OAuth in Settings, or preview with Demo Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Preview Demo Data") {
                viewModel.toggleDemoMode()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button(viewModel.demoMode ? "Exit Demo" : "Demo") {
                viewModel.toggleDemoMode()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 12)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
