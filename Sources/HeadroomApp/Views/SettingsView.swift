import SwiftUI
import HeadroomCore

public struct SettingsView: View {
    @Bindable var viewModel: HeadroomViewModel

    @State private var selectedKind: CredentialKind = .sessionCookie
    @State private var secretInput: String = ""
    @State private var cliDirInput: String = ""
    @State private var newAccountProvider: ProviderID = .claude
    @State private var newAccountLabel: String = "work"
    @State private var newAccountCLIDir: String = ""
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
        .frame(width: 560, height: 500)
        .onAppear {
            viewModel.refreshCredentialSummaries()
            syncCLIDirField()
        }
        .onChange(of: viewModel.selectedSettingsProvider) {
            syncCLIDirField()
        }
        .onChange(of: viewModel.selectedSettingsAccountLabel) {
            syncCLIDirField()
        }
    }

    private func syncCLIDirField() {
        let match = viewModel.config.accounts.first {
            $0.provider == viewModel.selectedSettingsProvider && $0.label == viewModel.selectedSettingsAccountLabel
        }
        cliDirInput = match?.cliConfigDir ?? ""
    }

    private var accountsTab: some View {
        Form {
            Section("Configured Accounts (Work & Personal)") {
                ForEach(viewModel.config.accounts) { account in
                    let summary = viewModel.credentialSummaryByAccount[account.id] ?? "Not connected"
                    let connected = summary != "Not connected"
                    let isSelected = viewModel.selectedSettingsProvider == account.provider
                        && viewModel.selectedSettingsAccountLabel == account.label

                    HStack(spacing: 8) {
                        ProviderBadgeIcon(provider: account.provider, tint: connected ? HeadroomTheme.reserve : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(account.provider.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                AccountLabelPill(label: account.label)
                                if !account.enabled {
                                    Text("Paused")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(summary)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button(isSelected ? "Editing" : (connected ? "Manage" : "Connect")) {
                            viewModel.selectForSettings(provider: account.provider, accountLabel: account.label)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isSelected)

                        if viewModel.config.accounts.filter({ $0.provider == account.provider }).count > 1 {
                            Button(role: .destructive) {
                                viewModel.removeAccount(account)
                                feedbackMessage = "Removed \(account.provider.displayName) (\(account.label))."
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this account")
                        }
                    }
                }
            }

            Section("Add Another Account (e.g. Work vs. Personal)") {
                HStack(spacing: 8) {
                    Picker("Provider", selection: $newAccountProvider) {
                        ForEach(ProviderID.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    TextField("Label (e.g. work, personal)", text: $newAccountLabel)
                        .textFieldStyle(.roundedBorder)

                    Button("Add Account") {
                        feedbackMessage = viewModel.addAccount(
                            provider: newAccountProvider,
                            label: newAccountLabel,
                            cliConfigDir: newAccountCLIDir
                        )
                        newAccountCLIDir = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextField("Optional CLI profile folder (e.g. ~/.claude-work or ~/.codex-work)", text: $newAccountCLIDir)
                    .font(.caption)
            }

            Section("Credentials for \(viewModel.selectedSettingsProvider.displayName) (\(viewModel.selectedSettingsAccountLabel))") {
                Picker("Provider", selection: $viewModel.selectedSettingsProvider) {
                    ForEach(ProviderID.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                TextField("Account Label", text: $viewModel.selectedSettingsAccountLabel, prompt: Text("personal or work"))

                Picker("Credential Type", selection: $selectedKind) {
                    Text("Browser Session Cookie").tag(CredentialKind.sessionCookie)
                    Text("OAuth Token").tag(CredentialKind.oauthToken)
                    Text("API Key").tag(CredentialKind.apiKey)
                }

                SecureField("Paste cookie, token, or API key", text: $secretInput)

                if viewModel.selectedSettingsProvider == .claude || viewModel.selectedSettingsProvider == .codex || viewModel.selectedSettingsProvider == .gemini {
                    HStack {
                        TextField("Custom CLI folder (optional)", text: $cliDirInput, prompt: Text("~/.claude-work"))
                        Button("Save Folder") {
                            viewModel.updateAccountCLIDir(
                                provider: viewModel.selectedSettingsProvider,
                                accountLabel: viewModel.selectedSettingsAccountLabel,
                                cliConfigDir: cliDirInput
                            )
                            feedbackMessage = "Updated CLI folder for \(viewModel.selectedSettingsProvider.displayName) (\(viewModel.selectedSettingsAccountLabel))."
                        }
                        .controlSize(.small)
                    }
                }

                if viewModel.selectedSettingsProvider == .gemini,
                   let idx = viewModel.config.accounts.firstIndex(where: {
                       $0.provider == .gemini && $0.label == viewModel.selectedSettingsAccountLabel
                   }) {
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
                            accountLabel: viewModel.selectedSettingsAccountLabel,
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
                            accountLabel: viewModel.selectedSettingsAccountLabel
                        )
                        feedbackMessage = "Cleared Keychain credentials for \(viewModel.selectedSettingsProvider.displayName) (\(viewModel.selectedSettingsAccountLabel))."
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
