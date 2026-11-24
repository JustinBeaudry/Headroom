import SwiftUI
import HeadroomCore

public struct SettingsView: View {
    @Bindable var viewModel: HeadroomViewModel

    @State private var selectedAccountLabel: String = "personal"
    @State private var selectedKind: CredentialKind = .sessionCookie
    @State private var secretInput: String = ""
    @State private var feedbackMessage: String = ""

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            accountsTab
                .tabItem { Label("Accounts & Auth", systemImage: "key.fill") }

            pollingTab
                .tabItem { Label("Display & Polling", systemImage: "gauge.medium") }

            alertsTab
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
        }
        .frame(width: 520, height: 430)
        .onAppear {
            viewModel.refreshCredentialSummaries()
        }
    }

    private var accountsTab: some View {
        Form {
            Section("Discovered Connections") {
                ForEach(ProviderID.allCases) { provider in
                    let summary = viewModel.credentialSummaryByProvider[provider] ?? "Not connected"
                    let connected = summary != "Not connected"
                    HStack(spacing: 8) {
                        ProviderBadgeIcon(provider: provider, tint: connected ? HeadroomTheme.reserve : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(summary)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(connected ? "Manage" : "Connect") {
                            viewModel.selectedSettingsProvider = provider
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            Section("Store Keychain Credential (Zero Passwords)") {
                Picker("Provider", selection: $viewModel.selectedSettingsProvider) {
                    ForEach(ProviderID.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                TextField("Account Label", text: $selectedAccountLabel, prompt: Text("personal"))
                Picker("Credential Type", selection: $selectedKind) {
                    Text("Browser Session Cookie").tag(CredentialKind.sessionCookie)
                    Text("OAuth Token").tag(CredentialKind.oauthToken)
                    Text("API Key").tag(CredentialKind.apiKey)
                }
                SecureField("Paste cookie, token, or API key", text: $secretInput)

                if viewModel.selectedSettingsProvider == .gemini,
                   let idx = viewModel.config.accounts.firstIndex(where: { $0.provider == .gemini }) {
                    Picker("Gemini Quota Lane", selection: Binding(
                        get: { viewModel.config.accounts[idx].geminiLane ?? .auto },
                        set: { newLane in
                            viewModel.config.accounts[idx].geminiLane = newLane
                            viewModel.saveConfigAsync()
                        }
                    )) {
                        ForEach(GeminiLane.allCases, id: \.self) { lane in
                            Text(lane.displayName).tag(lane)
                        }
                    }
                }

                HStack {
                    Button("Save to Keychain") {
                        feedbackMessage = viewModel.saveCredential(
                            value: secretInput,
                            provider: viewModel.selectedSettingsProvider,
                            accountLabel: selectedAccountLabel.isEmpty ? "personal" : selectedAccountLabel,
                            kind: selectedKind
                        )
                        secretInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Open Provider Page") {
                        viewModel.openReauth(for: viewModel.selectedSettingsProvider)
                    }

                    Spacer()

                    Button("Clear Auth", role: .destructive) {
                        viewModel.clearCredentials(
                            provider: viewModel.selectedSettingsProvider,
                            accountLabel: selectedAccountLabel.isEmpty ? "personal" : selectedAccountLabel
                        )
                        feedbackMessage = "Cleared Keychain credentials for \(viewModel.selectedSettingsProvider.displayName)."
                    }
                }

                if !feedbackMessage.isEmpty {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var pollingTab: some View {
        Form {
            Section("Menu Bar Presentation") {
                Picker("Display Style", selection: $viewModel.config.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: viewModel.config.menuBarDisplayMode) {
                    viewModel.saveConfigAsync()
                }

                Toggle("Deduplicate X Subscription Shared Pool (Cursor + Grok)", isOn: $viewModel.config.deduplicateSharedPools)
                    .onChange(of: viewModel.config.deduplicateSharedPools) {
                        viewModel.saveConfigAsync()
                    }
            }

            Section("Adaptive Polling Cadence") {
                Stepper(
                    "Active Coding Interval: \(viewModel.config.polling.activeIntervalSec)s",
                    value: $viewModel.config.polling.activeIntervalSec,
                    in: 30...300,
                    step: 15
                )
                Stepper(
                    "Idle Interval: \(viewModel.config.polling.idleIntervalSec / 60)m",
                    value: $viewModel.config.polling.idleIntervalSec,
                    in: 300...3600,
                    step: 300
                )
                Button("Save Polling Settings") {
                    viewModel.saveConfigAsync()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }

    private var alertsTab: some View {
        Form {
            Section("Native macOS Notifications") {
                Toggle("Enable Notifications", isOn: $viewModel.config.alerts.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Low Headroom Threshold")
                        Spacer()
                        Text("\(Int(viewModel.config.alerts.lowHeadroomThresholdPercent))% left")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $viewModel.config.alerts.lowHeadroomThresholdPercent, in: 5...50, step: 5)
                }
                Toggle("Warn when projected to run out before reset", isOn: $viewModel.config.alerts.notifyProjectedExhaustion)
                Toggle("Notify when a quota window resets", isOn: $viewModel.config.alerts.notifyWindowReset)
                Toggle("Notify when a session cookie expires", isOn: $viewModel.config.alerts.notifyAuthExpired)
                Button("Save Alert Rules") {
                    viewModel.saveConfigAsync()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}
