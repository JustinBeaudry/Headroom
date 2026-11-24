import SwiftUI
import HeadroomCore

public struct SettingsView: View {
    @Bindable var viewModel: HeadroomViewModel

    @State private var selectedProvider: ProviderID = .claude
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
        .frame(width: 480, height: 370)
        .padding(14)
    }

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zero-Password Keychain Credentials")
                .font(.headline)
            Text("Headroom automatically reuses local CLI OAuth caches (~/.claude, ~/.codex, ~/.gemini, Cursor state.vscdb). Add opt-in browser session cookies or API keys below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(ProviderID.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                TextField("Account Label (e.g. personal, work)", text: $selectedAccountLabel)
                Picker("Credential Type", selection: $selectedKind) {
                    Text("Session Cookie").tag(CredentialKind.sessionCookie)
                    Text("OAuth Token").tag(CredentialKind.oauthToken)
                    Text("API Key").tag(CredentialKind.apiKey)
                }
                SecureField("Paste cookie / token / API key", text: $secretInput)
            }

            HStack {
                Button("Save to Keychain") {
                    feedbackMessage = viewModel.saveCredential(
                        value: secretInput,
                        provider: selectedProvider,
                        accountLabel: selectedAccountLabel,
                        kind: selectedKind
                    )
                    secretInput = ""
                }
                .buttonStyle(.borderedProminent)

                Button("Clear Provider Auth", role: .destructive) {
                    viewModel.clearCredentials(provider: selectedProvider, accountLabel: selectedAccountLabel)
                    feedbackMessage = "Cleared Keychain credentials for \(selectedProvider.displayName)."
                }

                Spacer()

                if selectedProvider == .gemini,
                   let idx = viewModel.config.accounts.firstIndex(where: { $0.provider == .gemini }) {
                    Picker("Gemini Lane", selection: Binding(
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
                    .frame(width: 190)
                }
            }

            if !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var pollingTab: some View {
        Form {
            Picker("Menu Bar Style", selection: $viewModel.config.menuBarDisplayMode) {
                ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Toggle("Deduplicate X Subscription Shared Pool (Cursor + Grok)", isOn: $viewModel.config.deduplicateSharedPools)
            Stepper("Active Poll Interval: \(viewModel.config.polling.activeIntervalSec)s",
                    value: $viewModel.config.polling.activeIntervalSec, in: 30...300, step: 15)
            Stepper("Idle Poll Interval: \(viewModel.config.polling.idleIntervalSec / 60)m",
                    value: $viewModel.config.polling.idleIntervalSec, in: 300...3600, step: 300)
            Button("Apply & Save") {
                viewModel.saveConfigAsync()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)
    }

    private var alertsTab: some View {
        Form {
            Toggle("Enable Native macOS Notifications", isOn: $viewModel.config.alerts.enabled)
            Slider(value: $viewModel.config.alerts.lowHeadroomThresholdPercent, in: 5...50, step: 5) {
                Text("Low Headroom Alert: \(Int(viewModel.config.alerts.lowHeadroomThresholdPercent))% left")
            }
            Toggle("Alert when projected to run out before reset", isOn: $viewModel.config.alerts.notifyProjectedExhaustion)
            Toggle("Alert when a quota window resets", isOn: $viewModel.config.alerts.notifyWindowReset)
            Toggle("Alert when a session cookie expires", isOn: $viewModel.config.alerts.notifyAuthExpired)
            Button("Save Alert Rules") {
                viewModel.saveConfigAsync()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)
    }
}
