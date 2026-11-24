import SwiftUI
import AppKit
import HeadroomCore

public struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var viewModel: HeadroomViewModel

    @State private var showAddAccountSheet = false

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            AccountsSettingsPane(viewModel: viewModel, showAddAccountSheet: $showAddAccountSheet)
                .tabItem { Label("Accounts", systemImage: "person.2.fill") }

            MenuBarSettingsPane(viewModel: viewModel)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            PollingAndAlertsPane(viewModel: viewModel)
                .tabItem { Label("Polling & Alerts", systemImage: "bell.badge") }

            UpdatesSettingsPane(viewModel: viewModel, openUpdateWindow: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "update-window")
            })
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 640, height: 470)
        .onAppear {
            viewModel.refreshCredentialSummaries()
        }
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Tab 1: Accounts (Master-Detail with Guided Setup)

private struct AccountsSettingsPane: View {
    @Bindable var viewModel: HeadroomViewModel
    @Binding var showAddAccountSheet: Bool

    @State private var selectedKind: CredentialKind = .sessionCookie
    @State private var secretInput: String = ""
    @State private var cliDirInput: String = ""
    @State private var feedbackMessage: String = ""
    @State private var feedbackIsError: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var showWebSignInSheet: Bool = false
    @State private var showManualSection: Bool = false

    private var selectedAccount: AccountConfig? {
        viewModel.config.accounts.first {
            $0.provider == viewModel.selectedSettingsProvider && $0.label == viewModel.selectedSettingsAccountLabel
        } ?? viewModel.config.accounts.first
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar: Configured Accounts
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(viewModel.config.accounts) { account in
                            let summary = viewModel.credentialSummaryByAccount[account.id] ?? "Not connected"
                            let connected = summary != "Not connected"
                            let isSelected = selectedAccount?.id == account.id

                            Button {
                                viewModel.selectForSettings(provider: account.provider, accountLabel: account.label)
                                feedbackMessage = ""
                            } label: {
                                HStack(spacing: 8) {
                                    ProviderBadgeIcon(
                                        provider: account.provider,
                                        tint: connected ? HeadroomTheme.reserve : .secondary
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(account.provider.displayName)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            AccountLabelPill(label: account.label)
                                        }
                                        Text(connected ? "Connected" : "Needs setup")
                                            .font(.system(size: 10))
                                            .foregroundStyle(connected ? HeadroomTheme.reserve : .secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }

                Divider()

                Button {
                    showAddAccountSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(10)
            }
            .frame(width: 215)
            .background(Color.primary.opacity(0.025))

            Divider()

            // Right detail pane: Guided setup for the selected account
            if let account = selectedAccount {
                accountDetailPane(for: account)
                    .id(account.id)
            } else {
                VStack(spacing: 10) {
                    Text("No accounts configured")
                        .font(.headline)
                    Button("Add Account") { showAddAccountSheet = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { syncInputs() }
        .onChange(of: viewModel.selectedSettingsProvider) { syncInputs() }
        .onChange(of: viewModel.selectedSettingsAccountLabel) { syncInputs() }
        .sheet(isPresented: $showWebSignInSheet) {
            if let account = selectedAccount {
                ProviderSignInSheet(provider: account.provider, accountLabel: account.label) { capturedCookie in
                    isTestingConnection = true
                    feedbackMessage = ""
                    Task {
                        let outcome = await viewModel.saveAndTestCredential(
                            value: capturedCookie,
                            provider: account.provider,
                            accountLabel: account.label,
                            kind: .sessionCookie
                        )
                        feedbackIsError = !outcome.ok
                        feedbackMessage = outcome.message
                        isTestingConnection = false
                    }
                }
            }
        }
    }

    private func syncInputs() {
        cliDirInput = selectedAccount?.cliConfigDir ?? ""
        secretInput = ""
        feedbackMessage = ""
        feedbackIsError = false
        if let p = selectedAccount?.provider {
            switch p {
            case .claude, .grok: selectedKind = .sessionCookie
            case .codex, .cursor: selectedKind = .oauthToken
            case .gemini: selectedKind = .apiKey
            }
        }
    }

    private func accountDetailPane(for account: AccountConfig) -> some View {
        let summary = viewModel.credentialSummaryByAccount[account.id] ?? "Not connected"
        let connected = summary != "Not connected"
        let canRemove = viewModel.config.accounts.filter { $0.provider == account.provider }.count > 1

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Account header
                HStack(spacing: 10) {
                    ProviderBadgeIcon(
                        provider: account.provider,
                        tint: connected ? HeadroomTheme.reserve : .secondary
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(account.provider.displayName)
                                .font(.system(size: 15, weight: .semibold))
                            AccountLabelPill(label: account.label)
                        }
                        Text(connected ? "Connected via \(summary)" : "Not connected yet")
                            .font(.system(size: 11))
                            .foregroundStyle(connected ? HeadroomTheme.reserve : .secondary)
                    }
                    Spacer()
                    if canRemove {
                        Button("Remove", role: .destructive) {
                            viewModel.removeAccount(account)
                            feedbackMessage = "Removed \(account.provider.displayName) (\(account.label))."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Primary One-Click Sign-In & CLI Import Card (zero DevTools required!)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect \(account.provider.displayName) (\(account.label.capitalized))")
                        .font(.system(size: 12.5, weight: .semibold))

                    if account.provider == .grok && viewModel.isCursorOnUnifiedXSubscription {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(HeadroomTheme.sharedPool)
                                .font(.system(size: 12))
                                .padding(.top, 1)
                            Text("Already tracked via Cursor (Unified X Subscription): your shared X Weekly Grok Pool is already live under Cursor. Sign in below only if you want standalone Grok or xAI API credits.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(HeadroomTheme.sharedPool.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    Text(quickConnectCaption(for: account.provider))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if ProviderSignInSheet.supportsWebSignIn(account.provider) {
                            Button {
                                showWebSignInSheet = true
                            } label: {
                                Label("Sign in to \(account.provider.displayName)", systemImage: "globe")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isTestingConnection)
                        }

                        if account.provider == .claude || account.provider == .codex {
                            Button {
                                isTestingConnection = true
                                feedbackMessage = ""
                                let folder = cliDirInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                viewModel.updateAccountCLIDir(
                                    provider: account.provider,
                                    accountLabel: account.label,
                                    cliConfigDir: folder
                                )
                                Task {
                                    let outcome: (ok: Bool, message: String)
                                    if account.provider == .claude {
                                        outcome = await viewModel.importClaudeCodeFromKeychain(
                                            accountLabel: account.label,
                                            cliConfigDir: folder.isEmpty ? nil : folder
                                        )
                                    } else {
                                        outcome = await viewModel.importCodexFromCLI(
                                            accountLabel: account.label,
                                            cliConfigDir: folder.isEmpty ? nil : folder
                                        )
                                    }
                                    feedbackIsError = !outcome.ok
                                    feedbackMessage = outcome.message
                                    isTestingConnection = false
                                }
                            } label: {
                                if isTestingConnection {
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.mini)
                                        Text("Connecting...")
                                    }
                                } else {
                                    let targetName = cliDirInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? (account.provider == .claude ? "~/.claude" : "~/.codex")
                                        : cliDirInput
                                    Label("Import from \(targetName)", systemImage: "terminal")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isTestingConnection)
                        }

                        if connected && summary.contains("keychain:") {
                            Spacer()
                            Button("Disconnect", role: .destructive) {
                                viewModel.clearCredentials(provider: account.provider, accountLabel: account.label)
                                feedbackIsError = false
                                feedbackMessage = "Disconnected \(account.provider.displayName) (\(account.label))."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Live test feedback banner
                if !feedbackMessage.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(feedbackIsError ? HeadroomTheme.burningFast : HeadroomTheme.reserve)
                            .font(.system(size: 12))
                            .padding(.top, 1)
                        Text(feedbackMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(feedbackIsError ? HeadroomTheme.burningFast : HeadroomTheme.reserve)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (feedbackIsError ? HeadroomTheme.burningFast : HeadroomTheme.reserve).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }

                // Gemini lane toggle
                if account.provider == .gemini {
                    let accountID = account.id
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gemini Quota Lane")
                            .font(.system(size: 12, weight: .semibold))
                        Picker("Lane", selection: Binding(
                            get: {
                                viewModel.config.accounts.first(where: { $0.id == accountID })?.geminiLane ?? .auto
                            },
                            set: { newLane in
                                if let idx = viewModel.config.accounts.firstIndex(where: { $0.id == accountID }) {
                                    viewModel.config.accounts[idx].geminiLane = newLane
                                    viewModel.saveConfigAsync()
                                }
                            }
                        )) {
                            ForEach(GeminiLane.allCases, id: \.self) { lane in
                                Text(lane.displayName).tag(lane)
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                // Advanced / Manual Cookie, API Key, & CLI Folder (cleanly collapsed by default)
                DisclosureGroup("Advanced: CLI Folder, Manual Cookie, or API Key", isExpanded: $showManualSection) {
                    VStack(alignment: .leading, spacing: 12) {
                        if account.provider == .claude || account.provider == .codex || account.provider == .gemini {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("CLI Profile Folder")
                                    .font(.system(size: 11.5, weight: .semibold))
                                HStack(spacing: 6) {
                                    TextField(account.provider == .claude ? "~/.claude" : "~/.codex", text: $cliDirInput)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Browse...") {
                                        if let chosen = pickFolderPanel() {
                                            cliDirInput = chosen
                                            viewModel.updateAccountCLIDir(
                                                provider: account.provider,
                                                accountLabel: account.label,
                                                cliConfigDir: chosen
                                            )
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Paste Credential Manually")
                                .font(.system(size: 11.5, weight: .semibold))

                            Picker("Type", selection: $selectedKind) {
                                Text("Session Cookie").tag(CredentialKind.sessionCookie)
                                Text("OAuth Token").tag(CredentialKind.oauthToken)
                                Text("API Key").tag(CredentialKind.apiKey)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            HStack(spacing: 6) {
                                SecureField(placeholderFor(provider: account.provider, kind: selectedKind), text: $secretInput)
                                    .textFieldStyle(.roundedBorder)

                                Button("Paste") {
                                    if let clip = NSPasteboard.general.string(forType: .string) {
                                        secretInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button(isTestingConnection ? "Testing..." : "Save & Test") {
                                isTestingConnection = true
                                feedbackMessage = ""
                                let toSave = secretInput
                                Task {
                                    let outcome = await viewModel.saveAndTestCredential(
                                        value: toSave,
                                        provider: account.provider,
                                        accountLabel: account.label,
                                        kind: selectedKind
                                    )
                                    feedbackIsError = !outcome.ok
                                    feedbackMessage = outcome.message
                                    if outcome.ok { secretInput = "" }
                                    isTestingConnection = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isTestingConnection || secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quickConnectCaption(for provider: ProviderID) -> String {
        switch provider {
        case .claude:
            return "Sign in inside a private isolated window (no DevTools or password storage), or import directly from your Claude Code CLI profile."
        case .codex:
            return "Sign in to ChatGPT/Codex in an isolated window, or import from your Codex CLI folder (~/.codex or ~/.codex-work)."
        case .cursor:
            return "Automatically uses your local Cursor desktop app login. Use Sign in to Cursor only if you want to connect an extra Cursor account."
        case .grok:
            return "Sign in to grok.com in an isolated window to capture your session automatically, or add an XAI_API_KEY under Advanced."
        case .gemini:
            return "Automatically reads ~/.gemini/oauth_creds.json from Gemini CLI. Switch lanes below or add a GEMINI_API_KEY under Advanced."
        }
    }

    private func setupInstructions(for provider: ProviderID, isSecondary: Bool) -> String {
        switch provider {
        case .claude:
            return "Easiest on macOS: click 'Import from Claude Code CLI' below to copy your existing Claude Code OAuth token from macOS Keychain (click Allow once). Or paste your claude.ai `sessionKey` cookie from browser DevTools -> Application -> Cookies."
        case .codex:
            if isSecondary {
                return "For a second ChatGPT/Codex account, either paste its `__Secure-next-auth.session-token` cookie from chatgpt.com or pick its separate Codex CLI folder (e.g. ~/.codex-work) below."
            }
            return "Headroom automatically reads ~/.codex/auth.json from Codex CLI. You can also paste a chatgpt.com session cookie or OpenAI API key below."
        case .cursor:
            return "Headroom automatically reads your signed-in Cursor desktop app token (including Unified X Subscription weekly pools). Paste a WorkosCursorSessionToken cookie only if you want to track an extra Cursor account."
        case .grok:
            return "Open grok.com/dashboard while signed in, copy the `sso` cookie from DevTools -> Cookies, and paste it below. Unified X Subscription accounts link automatically with Cursor."
        case .gemini:
            return "Headroom automatically reads ~/.gemini/oauth_creds.json for Gemini CLI. Switch the quota lane below if you use GCP Code Assist or a Gemini API key."
        }
    }

    private func placeholderFor(provider: ProviderID, kind: CredentialKind) -> String {
        switch (provider, kind) {
        case (.claude, .sessionCookie): return "Paste claude.ai sessionKey (starts with sk-ant-sid...)"
        case (.codex, .sessionCookie): return "Paste __Secure-next-auth.session-token cookie"
        case (.grok, .sessionCookie): return "Paste grok.com sso cookie"
        case (.cursor, .sessionCookie): return "Paste WorkosCursorSessionToken cookie"
        case (_, .oauthToken): return "Paste OAuth access token"
        case (_, .apiKey): return "Paste API key"
        case (_, .sessionCookie): return "Paste browser session cookie"
        }
    }
}

// MARK: - Guided "+ Add Account" Sheet

private struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: HeadroomViewModel

    @State private var provider: ProviderID = .claude
    @State private var label: String = "work"
    @State private var authMode: Int = 0 // 0 = Cookie/Token, 1 = CLI Folder
    @State private var credentialKind: CredentialKind = .sessionCookie
    @State private var secretValue: String = ""
    @State private var cliFolder: String = ""
    @State private var errorText: String = ""

    private let presetLabels = ["work", "personal", "client"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Account")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }

            // Step 1: Provider tiles
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Choose Provider")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(ProviderID.allCases) { p in
                        let selected = provider == p
                        Button {
                            provider = p
                            credentialKind = (p == .codex || p == .cursor) ? .oauthToken : .sessionCookie
                        } label: {
                            VStack(spacing: 5) {
                                ProviderBadgeIcon(provider: p, tint: selected ? HeadroomTheme.sharedPool : .secondary)
                                Text(p.displayName)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? HeadroomTheme.sharedPool.opacity(0.14) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? HeadroomTheme.sharedPool.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Step 2: Account label with 1-click presets
            VStack(alignment: .leading, spacing: 6) {
                Text("2. Account Label")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(presetLabels, id: \.self) { preset in
                        let active = label.lowercased() == preset
                        Button(preset.capitalized) {
                            label = preset
                        }
                        .buttonStyle(.bordered)
                        .tint(active ? HeadroomTheme.sharedPool : .secondary)
                        .controlSize(.small)
                    }
                    TextField("Custom label", text: $label)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Step 3: Optional immediate credential or CLI folder
            VStack(alignment: .leading, spacing: 8) {
                Text("3. Connect Now (Optional)")
                    .font(.system(size: 12, weight: .semibold))

                Picker("Method", selection: $authMode) {
                    Text("Cookie / Token / API Key").tag(0)
                    Text("Separate CLI Folder").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if authMode == 0 {
                    HStack(spacing: 8) {
                        Picker("Kind", selection: $credentialKind) {
                            Text("Cookie").tag(CredentialKind.sessionCookie)
                            Text("Token").tag(CredentialKind.oauthToken)
                            Text("API Key").tag(CredentialKind.apiKey)
                        }
                        .labelsHidden()
                        .frame(width: 100)

                        SecureField("Paste now, or leave blank to add later", text: $secretValue)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("e.g. ~/.claude-work or ~/.codex-work", text: $cliFolder)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose Folder...") {
                            if let folder = pickFolderPanel() {
                                cliFolder = folder
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(HeadroomTheme.burningFast)
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add Account") {
                    let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !clean.isEmpty else {
                        errorText = "Enter an account label (for example: work)."
                        return
                    }
                    if viewModel.config.accounts.contains(where: { $0.provider == provider && $0.label.lowercased() == clean }) {
                        errorText = "\(provider.displayName) (\(clean)) already exists."
                        return
                    }
                    _ = viewModel.addAccount(
                        provider: provider,
                        label: clean,
                        cliConfigDir: authMode == 1 ? cliFolder : nil
                    )
                    if authMode == 0 && !secretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = viewModel.saveCredential(
                            value: secretValue,
                            provider: provider,
                            accountLabel: clean,
                            kind: credentialKind
                        )
                    } else if authMode == 1 && !cliFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let folder = cliFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            if provider == .claude {
                                _ = await viewModel.importClaudeCodeFromKeychain(accountLabel: clean, cliConfigDir: folder)
                            } else if provider == .codex {
                                _ = await viewModel.importCodexFromCLI(accountLabel: clean, cliConfigDir: folder)
                            }
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440, height: 370)
    }
}

// MARK: - Tab 2: Menu Bar (iStat-Style Customizer + Live Preview)

private struct MenuBarSettingsPane: View {
    @Bindable var viewModel: HeadroomViewModel

    private var previewItems: [MenuBarItemSnapshot] {
        let live = viewModel.menuBarDisplayItems
        if !live.isEmpty { return live }
        return [
            MenuBarItemSnapshot(id: "preview:claude", shortLabel: "CLD", fullName: "Claude", headroomPercent: 64, usedPercent: 36, pace: .onTrack, isAuthExpired: false),
            MenuBarItemSnapshot(id: "preview:codex", shortLabel: "CDX", fullName: "Codex", headroomPercent: 92, usedPercent: 8, pace: .reserve, isAuthExpired: false),
            MenuBarItemSnapshot(id: "preview:cursor", shortLabel: "CUR", fullName: "Cursor", headroomPercent: 18, usedPercent: 82, pace: .burningFast, isAuthExpired: false)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Live macOS menu bar preview strip
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIVE MENU BAR PREVIEW")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    HStack {
                        Spacer()
                        let previewImg = MenuBarRenderer.render(
                            items: previewItems,
                            displayMode: viewModel.config.menuBarDisplayMode,
                            metricMode: viewModel.config.menuBarMetricMode,
                            colorize: viewModel.config.menuBarColorize,
                            privacyMode: false,
                            forceLightText: true
                        )
                        Image(nsImage: previewImg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Spacer()
                    }
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.11, blue: 0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                    )
                }

                // Style & Metric Mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("Layout & Metric")
                        .font(.system(size: 12.5, weight: .semibold))

                    HStack {
                        Text("Percentage Shown")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("Metric", selection: $viewModel.config.menuBarMetricMode) {
                            Text("Remaining % (Left)").tag(MenuBarMetricMode.remaining)
                            Text("Used % (Spent)").tag(MenuBarMetricMode.used)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        .onChange(of: viewModel.config.menuBarMetricMode) {
                            viewModel.saveConfigAsync()
                        }
                    }

                    HStack {
                        Text("Display Style")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("Style", selection: $viewModel.config.menuBarDisplayMode) {
                            ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: viewModel.config.menuBarDisplayMode) {
                            viewModel.saveConfigAsync()
                        }
                    }

                    Text(viewModel.config.menuBarDisplayMode.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Color-code percentages by headroom & pace (emerald / amber / red)", isOn: $viewModel.config.menuBarColorize)
                        .font(.system(size: 12))
                        .onChange(of: viewModel.config.menuBarColorize) {
                            viewModel.saveConfigAsync()
                        }

                    Toggle("Deduplicate X Subscription Shared Pool (Cursor + Grok)", isOn: $viewModel.config.deduplicateSharedPools)
                        .font(.system(size: 12))
                        .onChange(of: viewModel.config.deduplicateSharedPools) {
                            viewModel.saveConfigAsync()
                        }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                // Pinned Providers Checklist
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Providers Shown in Menu Bar")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        if !viewModel.config.menuBarPinnedAccounts.isEmpty {
                            Button("Auto (All Live)") {
                                viewModel.clearMenuBarPins()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        } else {
                            Text("Auto (all connected)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Check specific accounts to pin only those to the menu bar, or leave all unchecked to show every connected provider automatically.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(viewModel.config.accounts) { account in
                            let isPinned = viewModel.config.menuBarPinnedAccounts.contains(account.id)
                            Toggle(isOn: Binding(
                                get: { isPinned },
                                set: { _ in viewModel.toggleMenuBarPinned(account.id) }
                            )) {
                                HStack(spacing: 5) {
                                    Text(account.provider.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                    AccountLabelPill(label: account.label)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(18)
        }
    }
}

// MARK: - Tab 3: Polling & Alerts

private struct PollingAndAlertsPane: View {
    @Bindable var viewModel: HeadroomViewModel

    var body: some View {
        Form {
            Section("Adaptive Polling") {
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
            }

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
                Button("Save Preferences") {
                    viewModel.saveConfigAsync()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 4: Updates

private struct UpdatesSettingsPane: View {
    @Bindable var viewModel: HeadroomViewModel
    let openUpdateWindow: () -> Void

    private var isInstalling: Bool {
        switch viewModel.updateProgress {
        case .downloading, .verifying, .installing: return true
        case .idle, .failed: return false
        }
    }

    private var progressText: String? {
        switch viewModel.updateProgress {
        case .idle: return nil
        case .downloading: return "Downloading signed release archive..."
        case .verifying: return "Verifying SHA-256 checksum & Apple Developer signature..."
        case .installing: return "Installing update & relaunching Headroom..."
        case .failed(let msg): return msg
        }
    }

    var body: some View {
        Form {
            Section("Software Updates") {
                HStack {
                    Text("Installed Version")
                    Spacer()
                    Text(viewModel.currentAppVersion.tagString)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Toggle("Check for new GitHub releases automatically", isOn: $viewModel.autoCheckUpdates)

                if let lastChecked = viewModel.lastUpdateCheckAt {
                    HStack {
                        Text("Last Checked")
                        Spacer()
                        Text(lastChecked, style: .relative)
                            .foregroundStyle(.secondary)
                        Text("ago")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.checkForUpdates(manual: true) }
                    } label: {
                        if viewModel.isCheckingForUpdates {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking...")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isCheckingForUpdates || isInstalling)

                    if let latest = viewModel.latestKnownRelease, viewModel.availableUpdate == nil {
                        Button("Release Notes (\(latest.tagName))") {
                            openUpdateWindow()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let status = viewModel.updateStatusMessage, viewModel.availableUpdate == nil {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let release = viewModel.availableUpdate {
                Section("Update Available: \(release.tagName)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("\(viewModel.currentAppVersion.tagString) -> \(release.tagName)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(HeadroomTheme.sharedPool)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(HeadroomTheme.sharedPool.opacity(0.14), in: Capsule())

                            if let published = release.publishedAt {
                                Text("Released")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(published, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(release.summaryHighlight)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let progressText {
                            HStack(spacing: 6) {
                                if isInstalling {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(HeadroomTheme.burningFast)
                                }
                                Text(progressText)
                                    .font(.caption)
                                    .foregroundStyle(isInstalling ? .secondary : HeadroomTheme.burningFast)
                            }
                        }

                        HStack(spacing: 8) {
                            Button(viewModel.isRunningFromAppBundle ? "Install & Relaunch" : "Download Release") {
                                Task { await viewModel.installAvailableUpdate() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstalling)

                            Button("What's New") {
                                openUpdateWindow()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isInstalling)

                            Button("View on GitHub") {
                                NSWorkspace.shared.open(release.htmlURL)
                            }
                            .buttonStyle(.link)
                            .disabled(isInstalling)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Native Folder Picker Helper

@MainActor
private func pickFolderPanel() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Select CLI Folder"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if url.path.hasPrefix(home) {
        return "~" + url.path.dropFirst(home.count)
    }
    return url.path
}
