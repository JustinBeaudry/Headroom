import Foundation
import SwiftUI
import AppKit
import HeadroomCore

public struct UrgentMenuItem: Sendable {
    public let label: String
    public let shortCode: String
    public let accountLabel: String
    public let showAccountBadge: Bool
    public let headroomPercent: Double
    public let pace: PaceStatus
    public let isAuthExpired: Bool

    public var menuBarCode: String {
        guard showAccountBadge, let first = accountLabel.first else {
            return shortCode
        }
        return "\(shortCode)·\(String(first).uppercased())"
    }
}

public struct MiniBarEntry: Sendable, Identifiable {
    public let id: String
    public let headroomPercent: Double
    public let pace: PaceStatus
    public let isError: Bool
}

@MainActor
@Observable
public final class HeadroomViewModel {
    public var state: HeadroomState = HeadroomState(snapshots: [])
    public var config: HeadroomConfig = HeadroomConfig()
    public var isRefreshing: Bool = false
    public var hasCompletedInitialLoad: Bool = false
    public var privacyMode: Bool = false
    public var lastAlerts: [HeadroomAlert] = []
    public var isActivePolling: Bool = true
    public var nextPollSeconds: Int = 90
    public var selectedAccountFilter: String? = nil // nil = All accounts
    public var selectedSettingsProvider: ProviderID = .claude
    public var selectedSettingsAccountLabel: String = "personal"
    public var credentialSummaryByAccount: [String: String] = [:]

    // In-app release update state
    public var availableUpdate: ReleaseInfo? = nil
    public var latestKnownRelease: ReleaseInfo? = nil
    public var isUpdateBannerDismissed: Bool = false
    public var isCheckingForUpdates: Bool = false
    public var updateStatusMessage: String? = nil
    public var updateProgress: AppUpdateProgress = .idle
    public var lastUpdateCheckAt: Date? = nil
    public var autoCheckUpdates: Bool = true {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Self.autoCheckUpdatesKey)
        }
    }
    public var skippedUpdateTag: String? = nil {
        didSet {
            UserDefaults.standard.set(skippedUpdateTag, forKey: Self.skippedUpdateTagKey)
        }
    }

    private static let autoCheckUpdatesKey = "headroom.autoCheckUpdates"
    private static let skippedUpdateTagKey = "headroom.skippedUpdateTag"
    private static let notifiedUpdateTagKey = "headroom.notifiedUpdateTag"

    private let engine: HeadroomEngine
    private let keychain: KeychainStore
    private let discovery: CredentialDiscovery
    private let notifications: NotificationManager
    private let updateChecker: UpdateChecker
    private let appUpdater: AppUpdater
    private var pollingTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    public init(
        engine: HeadroomEngine = HeadroomEngine(),
        keychain: KeychainStore = KeychainStore(),
        notifications: NotificationManager = NotificationManager(),
        updateChecker: UpdateChecker = UpdateChecker(),
        appUpdater: AppUpdater = AppUpdater()
    ) {
        self.engine = engine
        self.keychain = keychain
        self.discovery = CredentialDiscovery(secretStore: keychain)
        self.notifications = notifications
        self.updateChecker = updateChecker
        self.appUpdater = appUpdater
        if UserDefaults.standard.object(forKey: Self.autoCheckUpdatesKey) != nil {
            self.autoCheckUpdates = UserDefaults.standard.bool(forKey: Self.autoCheckUpdatesKey)
        }
        self.skippedUpdateTag = UserDefaults.standard.string(forKey: Self.skippedUpdateTagKey)
    }

    public var currentAppVersion: AppVersion {
        AppVersion.currentBundleVersion()
    }

    public var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public var visibleBannerUpdate: ReleaseInfo? {
        guard let release = availableUpdate,
              !isUpdateBannerDismissed,
              release.tagName != skippedUpdateTag else {
            return nil
        }
        return release
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.notifications.requestAuthorizationIfAvailable()
            self.config = await self.engine.loadConfig()
            self.refreshCredentialSummaries()
            if let cached = await self.engine.loadCachedState(), !cached.snapshots.isEmpty {
                self.state = cached
                self.hasCompletedInitialLoad = true
            }
            await self.refresh(force: false)

            while !Task.isCancelled {
                let interval = await self.engine.nextRecommendedInterval()
                self.nextPollSeconds = Int(interval)
                self.isActivePolling = await self.engine.isUserActive()
                try? await Task.sleep(nanoseconds: UInt64(max(30, interval)) * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refresh(force: false)
            }
        }

        if updateTask == nil {
            updateTask = Task { [weak self] in
                guard let self else { return }
                // Wait a few seconds after startup so quota polling completes first
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                while !Task.isCancelled {
                    if self.autoCheckUpdates {
                        await self.checkForUpdates(manual: false)
                    }
                    // Check again every 6 hours
                    try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                }
            }
        }
    }

    public func checkForUpdates(manual: Bool) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer {
            isCheckingForUpdates = false
            lastUpdateCheckAt = Date()
        }

        let result = await updateChecker.checkForUpdates(currentVersion: currentAppVersion)
        switch result {
        case .updateAvailable(_, let release):
            latestKnownRelease = release
            availableUpdate = release
            if manual {
                isUpdateBannerDismissed = false
                if skippedUpdateTag == release.tagName {
                    skippedUpdateTag = nil
                }
            }
            updateStatusMessage = "Headroom \(release.tagName) is available."

            let lastNotified = UserDefaults.standard.string(forKey: Self.notifiedUpdateTagKey)
            if lastNotified != release.tagName && skippedUpdateTag != release.tagName {
                notifications.notifyUpdateAvailable(release)
                UserDefaults.standard.set(release.tagName, forKey: Self.notifiedUpdateTagKey)
            }

        case .upToDate(let current, let latest):
            latestKnownRelease = latest
            availableUpdate = nil
            updateStatusMessage = "Headroom \(current.tagString) is up to date."

        case .failed(let message):
            if manual {
                updateStatusMessage = message
            }
        }
    }

    public func dismissUpdateBanner() {
        isUpdateBannerDismissed = true
    }

    public func skipUpdate(_ release: ReleaseInfo) {
        skippedUpdateTag = release.tagName
        isUpdateBannerDismissed = true
    }

    public func installAvailableUpdate() async {
        guard let release = availableUpdate ?? latestKnownRelease else { return }
        guard isRunningFromAppBundle else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        updateProgress = .downloading
        do {
            try await appUpdater.downloadVerifyAndInstall(release: release) { [weak self] stage in
                Task { @MainActor in
                    self?.updateProgress = stage
                }
            }
            // Terminate so the handoff installer script atomically swaps Headroom.app and relaunches
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSApplication.shared.terminate(nil)
        } catch {
            updateProgress = .failed(error.localizedDescription)
        }
    }

    public func refresh(force: Bool = true) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            hasCompletedInitialLoad = true
        }

        if force {
            await engine.resetBackoff()
        }
        let result = await engine.poll(force: force)
        self.state = result.state
        self.isActivePolling = await engine.isUserActive()
        self.nextPollSeconds = Int(await engine.nextRecommendedInterval())
        if let filter = selectedAccountFilter, !availableAccountLabels.contains(filter) {
            selectedAccountFilter = nil
        }
        refreshCredentialSummaries()
        if !result.alerts.isEmpty {
            self.lastAlerts = Array((result.alerts + self.lastAlerts).prefix(10))
            notifications.deliver(result.alerts)
        }
    }

    public func refreshCredentialSummaries() {
        var map: [String: String] = [:]
        for account in config.accounts {
            let creds = discovery.discover(for: account)
            if creds.isEmpty {
                map[account.id] = "Not connected"
            } else {
                map[account.id] = creds.map(\.source).joined(separator: ", ")
            }
        }
        credentialSummaryByAccount = map
    }

    public func toggleDisplayMode() {
        let all = MenuBarDisplayMode.allCases
        if let idx = all.firstIndex(of: config.menuBarDisplayMode) {
            config.menuBarDisplayMode = all[(idx + 1) % all.count]
        } else {
            config.menuBarDisplayMode = .stackedMetrics
        }
        saveConfigAsync()
    }

    public func toggleMenuBarPinned(_ accountId: String) {
        if let idx = config.menuBarPinnedAccounts.firstIndex(of: accountId) {
            config.menuBarPinnedAccounts.remove(at: idx)
        } else {
            config.menuBarPinnedAccounts.append(accountId)
        }
        saveConfigAsync()
    }

    public func clearMenuBarPins() {
        config.menuBarPinnedAccounts = []
        saveConfigAsync()
    }

    public func saveConfigAsync() {
        let updated = config
        refreshCredentialSummaries()
        Task {
            try? await engine.saveConfig(updated)
            await refresh(force: false)
        }
    }

    // MARK: - Multi-Account Management

    public func addAccount(provider: ProviderID, label rawLabel: String, cliConfigDir: String? = nil) -> String {
        let cleanLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanLabel.isEmpty else { return "Account label cannot be empty." }
        if config.accounts.contains(where: { $0.provider == provider && $0.label.lowercased() == cleanLabel }) {
            return "\(provider.displayName) (\(cleanLabel)) already exists."
        }
        let isFirstForProvider = !config.accounts.contains(where: { $0.provider == provider })
        let cleanDir = cliConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAccount = AccountConfig(
            provider: provider,
            label: cleanLabel,
            enabled: true,
            geminiLane: provider == .gemini ? .auto : nil,
            dailyRequestLimit: provider == .gemini ? 1000 : nil,
            useLocalCLIDiscovery: isFirstForProvider,
            cliConfigDir: (cleanDir?.isEmpty == false) ? cleanDir : nil
        )
        config.accounts.append(newAccount)
        selectedSettingsProvider = provider
        selectedSettingsAccountLabel = cleanLabel
        saveConfigAsync()
        return "Added \(provider.displayName) (\(cleanLabel))."
    }

    public func removeAccount(_ account: AccountConfig) {
        for kind in CredentialKind.allCases {
            try? keychain.deleteSecret(provider: account.provider, accountLabel: account.label, kind: kind)
        }
        config.accounts.removeAll { $0.id == account.id }
        config.menuBarPinnedAccounts.removeAll { $0 == account.id }
        selectedAccountFilter = nil
        if let first = config.accounts.first {
            selectedSettingsProvider = first.provider
            selectedSettingsAccountLabel = first.label
        }
        saveConfigAsync()
    }

    public func updateAccountCLIDir(provider: ProviderID, accountLabel: String, cliConfigDir: String) {
        guard let idx = config.accounts.firstIndex(where: { $0.provider == provider && $0.label == accountLabel }) else {
            return
        }
        let trimmed = cliConfigDir.trimmingCharacters(in: .whitespacesAndNewlines)
        config.accounts[idx].cliConfigDir = trimmed.isEmpty ? nil : trimmed
        saveConfigAsync()
    }

    public func saveCredential(
        value: String,
        provider: ProviderID,
        accountLabel rawLabel: String,
        kind: CredentialKind
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Credential cannot be empty." }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalLabel = label.isEmpty ? "personal" : label

        // Automatically register the account in config.accounts if it doesn't exist yet
        if !config.accounts.contains(where: { $0.provider == provider && $0.label == finalLabel }) {
            let isFirstForProvider = !config.accounts.contains(where: { $0.provider == provider })
            config.accounts.append(AccountConfig(
                provider: provider,
                label: finalLabel,
                enabled: true,
                useLocalCLIDiscovery: isFirstForProvider
            ))
            let updatedConfig = config
            Task { try? await engine.saveConfig(updatedConfig) }
        }

        do {
            try keychain.setSecret(trimmed, provider: provider, accountLabel: finalLabel, kind: kind)
            refreshCredentialSummaries()
            Task { await refresh(force: true) }
            return "Saved \(kind.rawValue) in Keychain for \(provider.displayName) (\(finalLabel))."
        } catch {
            return "Keychain error: \(error.localizedDescription)"
        }
    }

    /// Saves a credential to Keychain, immediately polls that provider, and returns live diagnostic feedback.
    public func saveAndTestCredential(
        value: String,
        provider: ProviderID,
        accountLabel rawLabel: String,
        kind: CredentialKind
    ) async -> (ok: Bool, message: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "Credential cannot be empty.") }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalLabel = label.isEmpty ? "personal" : label

        if !config.accounts.contains(where: { $0.provider == provider && $0.label == finalLabel }) {
            let isFirstForProvider = !config.accounts.contains(where: { $0.provider == provider })
            config.accounts.append(AccountConfig(
                provider: provider,
                label: finalLabel,
                enabled: true,
                useLocalCLIDiscovery: isFirstForProvider
            ))
            try? await engine.saveConfig(config)
        }

        do {
            try keychain.setSecret(trimmed, provider: provider, accountLabel: finalLabel, kind: kind)
        } catch {
            return (false, "Keychain error: \(error.localizedDescription)")
        }

        refreshCredentialSummaries()
        await engine.resetBackoff()
        let result = await engine.poll(providers: [provider], force: true)
        self.state = result.state
        refreshCredentialSummaries()

        if let snap = result.state.snapshots.first(where: { $0.provider == provider && $0.accountLabel == finalLabel }) {
            return formatTestOutcome(for: snap)
        }
        return (true, "Saved in Keychain for \(provider.displayName) (\(finalLabel)).")
    }

    /// Explicitly imports Claude Code's OAuth token from macOS Login Keychain (profile-aware:
    /// `"Claude Code-credentials"` for ~/.claude, or `"Claude Code-credentials-<sha256_8>"` for custom folders
    /// like `~/.claude-work`), saves into Headroom's Keychain, and tests live usage.
    public func importClaudeCodeFromKeychain(accountLabel: String, cliConfigDir: String? = nil) async -> (ok: Bool, message: String) {
        let dir = cliConfigDir ?? config.accounts.first(where: { $0.provider == .claude && $0.label == accountLabel })?.cliConfigDir
        let serviceName = CredentialDiscovery.claudeKeychainServiceName(for: dir)
        guard let token = discovery.importClaudeCodeKeychainToken(cliConfigDir: dir), !token.isEmpty else {
            return (false, "Could not read '\(serviceName)' from macOS Keychain. Sign in with `CLAUDE_CONFIG_DIR=\(dir ?? "~/.claude") claude` and click Allow if macOS prompts.")
        }
        return await saveAndTestCredential(
            value: token,
            provider: .claude,
            accountLabel: accountLabel,
            kind: .oauthToken
        )
    }

    /// Explicitly imports Codex CLI credentials for `~/.codex` or a custom `CODEX_HOME` folder (e.g. `~/.codex-work`),
    /// supporting both `auth.json` and macOS Keychain (`Codex Auth` / `cli|<sha256_16>`), and tests live usage.
    public func importCodexFromCLI(accountLabel: String, cliConfigDir: String? = nil) async -> (ok: Bool, message: String) {
        let dir = cliConfigDir ?? config.accounts.first(where: { $0.provider == .codex && $0.label == accountLabel })?.cliConfigDir
        let acctKey = CredentialDiscovery.codexKeychainAccountName(for: dir)
        guard let cred = discovery.importCodexCLICredential(cliConfigDir: dir) else {
            return (false, "No Codex token found in \(dir ?? "~/.codex")/auth.json or Keychain ('Codex Auth' / '\(acctKey)'). Run `CODEX_HOME=\(dir ?? "~/.codex") codex login` and click Allow if macOS prompts.")
        }
        return await saveAndTestCredential(
            value: cred.value,
            provider: .codex,
            accountLabel: accountLabel,
            kind: cred.kind
        )
    }

    private func formatTestOutcome(for snap: ProviderSnapshot) -> (Bool, String) {
        switch snap.status {
        case .ok:
            if snap.windows.isEmpty {
                return (true, "Connected to \(snap.provider.displayName), no active quota limits reported.")
            }
            let summary = snap.windows.map { "\($0.label): \(Int($0.headroomPercent.rounded()))% left" }.joined(separator: " · ")
            return (true, "Connected! \(summary)")
        case .authExpired:
            return (false, snap.message ?? "Authentication rejected. Double-check the cookie/token value.")
        case .incident:
            return (false, snap.message ?? "Provider returned an error during connection test.")
        case .stale:
            return (false, snap.message ?? "Fell back to local telemetry; live quota check did not succeed.")
        case .unconfigured:
            return (false, snap.message ?? "Credential was not recognized.")
        }
    }

    public var isCursorOnUnifiedXSubscription: Bool {
        state.snapshots.contains { $0.provider == .cursor && $0.billingModel == .xSubscriptionUnified }
    }

    public var isAgyHookInstalled: Bool {
        AgyStatusBridge.isHookInstalled()
    }

    /// Installs the official Antigravity CLI (`agy`) statusLine hook pointing to this app's embedded CLI helper
    /// so `agy` streams live quota, reset times, and plan tier directly into Headroom.
    public func installAntigravityHook() async -> (ok: Bool, message: String) {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/headroom")
        let binaryPath: String
        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            binaryPath = helperURL.path
        } else if FileManager.default.isExecutableFile(atPath: "/Applications/Headroom.app/Contents/Helpers/headroom") {
            binaryPath = "/Applications/Headroom.app/Contents/Helpers/headroom"
        } else {
            binaryPath = "headroom"
        }

        do {
            let settingsURL = try AgyStatusBridge.installStatusLineHook(headroomBinaryPath: binaryPath)
            if let idx = config.accounts.firstIndex(where: { $0.provider == .gemini && $0.label == selectedSettingsAccountLabel }) {
                config.accounts[idx].geminiLane = .antigravity
                try? await engine.saveConfig(config)
            }
            await refresh(force: true)
            return (true, "Installed official `agy` statusLine hook in \(settingsURL.path). Your next `agy` turn will stream live Antigravity quota directly into Headroom!")
        } catch {
            return (false, "Could not configure ~/.gemini/antigravity-cli/settings.json: \(error.localizedDescription)")
        }
    }

    public func clearCredentials(provider: ProviderID, accountLabel: String) {
        for kind in CredentialKind.allCases {
            try? keychain.deleteSecret(provider: provider, accountLabel: accountLabel, kind: kind)
        }
        refreshCredentialSummaries()
        Task { await refresh(force: true) }
    }

    public func openReauth(for provider: ProviderID) {
        if let url = provider.reauthURL {
            NSWorkspace.shared.open(url)
        }
    }

    public func selectForSettings(provider: ProviderID, accountLabel: String? = nil) {
        selectedSettingsProvider = provider
        if let accountLabel {
            selectedSettingsAccountLabel = accountLabel
        } else if let first = config.accounts.first(where: { $0.provider == provider }) {
            selectedSettingsAccountLabel = first.label
        }
    }

    // MARK: - Derived View Collections

    /// Distinct account labels present in the current state (for filter pills).
    public var availableAccountLabels: [String] {
        let fromState = Set(state.snapshots.map(\.accountLabel))
        let fromConfig = Set(config.accounts.filter(\.enabled).map(\.label))
        let combined = fromState.union(fromConfig)
        return combined.sorted { lhs, rhs in
            if lhs == "personal" { return true }
            if rhs == "personal" { return false }
            if lhs == "work" { return true }
            if rhs == "work" { return false }
            return lhs < rhs
        }
    }

    public var hasMultipleAccounts: Bool {
        availableAccountLabels.count > 1
    }

    public func hasMultipleAccounts(for provider: ProviderID) -> Bool {
        let countInState = Set(state.snapshots.filter { $0.provider == provider }.map(\.accountLabel)).count
        let countInConfig = Set(config.accounts.filter { $0.provider == provider && $0.enabled }.map(\.label)).count
        return max(countInState, countInConfig) > 1
    }

    public var effectiveAccountFilter: String? {
        guard let filter = selectedAccountFilter, availableAccountLabels.contains(filter) else {
            return nil
        }
        return filter
    }

    public var filteredSharedPools: [SharedPoolGroup] {
        guard let filter = effectiveAccountFilter else { return state.sharedPools }
        return state.sharedPools.filter { $0.accountLabel == filter }
    }

    public var standaloneSnapshots: [ProviderSnapshot] {
        let allStandalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        guard let filter = effectiveAccountFilter else { return allStandalone }
        return allStandalone.filter { $0.accountLabel == filter }
    }

    /// Providers with live quota data, local telemetry, or actionable errors.
    public var activeSnapshots: [ProviderSnapshot] {
        standaloneSnapshots
            .filter { $0.status != .unconfigured }
            .sorted { lhs, rhs in
                let lhsRank = sortRank(lhs)
                let rhsRank = sortRank(rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                if lhs.urgencyScore != rhs.urgencyScore { return lhs.urgencyScore > rhs.urgencyScore }
                return lhs.id < rhs.id
            }
    }

    /// Providers that have not been connected yet (rendered compactly at bottom).
    public var unconfiguredSnapshots: [ProviderSnapshot] {
        standaloneSnapshots
            .filter { $0.status == .unconfigured }
            .sorted { $0.id < $1.id }
    }

    private func sortRank(_ snap: ProviderSnapshot) -> Int {
        switch snap.status {
        case .ok: return snap.windows.isEmpty ? 1 : 3
        case .authExpired, .incident: return 2
        case .stale: return snap.windows.isEmpty ? 1 : 2
        case .unconfigured: return 0
        }
    }

    public var relativeUpdatedText: String {
        if privacyMode {
            return "Screen-share privacy on"
        }
        if !hasCompletedInitialLoad {
            return "Checking quotas..."
        }
        let elapsed = Int(Date().timeIntervalSince(state.updatedAt))
        if elapsed < 15 {
            return "Updated just now"
        } else if elapsed < 60 {
            return "Updated \(elapsed)s ago"
        } else if elapsed < 3600 {
            return "Updated \(elapsed / 60)m ago"
        } else {
            return "Updated \(elapsed / 3600)h ago"
        }
    }

    public var pollingTooltip: String {
        let mode = isActivePolling ? "Active" : "Idle"
        let mins = nextPollSeconds >= 120 ? "\(nextPollSeconds / 60)m" : "\(nextPollSeconds)s"
        return "\(mode) polling every \(mins)"
    }

    public var bestAvailableSummary: (name: String, headroom: Int)? {
        var best: (String, Double)?
        for pool in filteredSharedPools {
            let h = pool.canonicalWindow.headroomPercent
            if best == nil || h > best!.1 { best = ("X Pool", h) }
        }
        for snap in standaloneSnapshots where snap.status == .ok {
            if let primary = snap.primaryWindow {
                let h = primary.headroomPercent
                let label = hasMultipleAccounts(for: snap.provider)
                    ? "\(snap.provider.displayName) (\(snap.accountLabel.capitalized))"
                    : snap.provider.displayName
                if best == nil || h > best!.1 { best = (label, h) }
            }
        }
        guard let best else { return nil }
        return (best.0, Int(best.1.rounded()))
    }

    public var nextResetSummary: (label: String, countdown: String)? {
        let now = Date()
        var candidates: [(label: String, date: Date, used: Double)] = []
        for pool in filteredSharedPools {
            if let reset = pool.canonicalWindow.resetsAt, reset > now {
                candidates.append(("X Pool", reset, pool.canonicalWindow.usedPercent))
            }
        }
        for snap in standaloneSnapshots where snap.status == .ok {
            for win in snap.windows {
                if let reset = win.resetsAt, reset > now {
                    candidates.append((snap.provider.displayName, reset, win.usedPercent))
                }
            }
        }
        let usedOnes = candidates.filter { $0.used > 0 }
        let poolToSearch = usedOnes.isEmpty ? candidates : usedOnes
        guard let soonest = poolToSearch.min(by: { $0.date < $1.date }) else { return nil }
        return (soonest.label, PaceCalculator.formatCountdown(until: soonest.date, now: now))
    }

    /// Most urgent live quota item for the menu bar.
    public var mostUrgentItem: UrgentMenuItem? {
        var liveCandidates: [(UrgentMenuItem, Double)] = []

        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            liveCandidates.append((
                UrgentMenuItem(
                    label: pool.label,
                    shortCode: "X",
                    accountLabel: pool.accountLabel,
                    showAccountBadge: false,
                    headroomPercent: w.headroomPercent,
                    pace: w.paceStatus,
                    isAuthExpired: false
                ),
                PaceCalculator.windowUrgency(w)
            ))
        }

        let allStandalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in allStandalone where snap.status == .ok {
            if let primary = snap.primaryWindow {
                liveCandidates.append((
                    UrgentMenuItem(
                        label: snap.provider.displayName,
                        shortCode: snap.provider.shortCode,
                        accountLabel: snap.accountLabel,
                        showAccountBadge: hasMultipleAccounts(for: snap.provider),
                        headroomPercent: primary.headroomPercent,
                        pace: primary.paceStatus,
                        isAuthExpired: false
                    ),
                    PaceCalculator.windowUrgency(primary)
                ))
            }
        }

        if let topLive = liveCandidates.max(by: { $0.1 < $1.1 }) {
            return topLive.0
        }

        if let expired = allStandalone.first(where: { $0.status == .authExpired }) {
            return UrgentMenuItem(
                label: expired.provider.displayName,
                shortCode: expired.provider.shortCode,
                accountLabel: expired.accountLabel,
                showAccountBadge: hasMultipleAccounts(for: expired.provider),
                headroomPercent: 0,
                pace: .burningFast,
                isAuthExpired: true
            )
        }
        return nil
    }

    /// Ordered list of live providers/pools to render in the menu bar (respects user pins or auto-picks live accounts).
    public var menuBarDisplayItems: [MenuBarItemSnapshot] {
        var candidatesById: [String: (MenuBarItemSnapshot, Double)] = [:]

        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            let item = MenuBarItemSnapshot(
                id: pool.id,
                shortLabel: "X",
                fullName: pool.label,
                headroomPercent: w.headroomPercent,
                usedPercent: w.usedPercent,
                pace: w.paceStatus,
                isAuthExpired: false
            )
            candidatesById[pool.id] = (item, PaceCalculator.windowUrgency(w))
        }

        let allStandalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in allStandalone {
            let multi = hasMultipleAccounts(for: snap.provider)
            let code: String
            if multi, let first = snap.accountLabel.first {
                code = "\(snap.provider.shortCode)·\(String(first).uppercased())"
            } else {
                code = snap.provider.shortCode
            }

            if snap.status == .ok, let primary = snap.primaryWindow {
                let item = MenuBarItemSnapshot(
                    id: snap.id,
                    shortLabel: code,
                    fullName: "\(snap.provider.displayName) (\(snap.accountLabel.capitalized))",
                    headroomPercent: primary.headroomPercent,
                    usedPercent: primary.usedPercent,
                    pace: primary.paceStatus,
                    isAuthExpired: false
                )
                candidatesById[snap.id] = (item, PaceCalculator.windowUrgency(primary))
            } else if snap.status == .authExpired {
                let item = MenuBarItemSnapshot(
                    id: snap.id,
                    shortLabel: code,
                    fullName: "\(snap.provider.displayName) (\(snap.accountLabel.capitalized))",
                    headroomPercent: 0,
                    usedPercent: 100,
                    pace: .burningFast,
                    isAuthExpired: true
                )
                candidatesById[snap.id] = (item, 75.0)
            }
        }

        // If user explicitly pinned accounts in Settings -> Menu Bar, show those in pinned order
        if !config.menuBarPinnedAccounts.isEmpty {
            let pinned = config.menuBarPinnedAccounts.compactMap { candidatesById[$0]?.0 }
            if !pinned.isEmpty {
                return pinned
            }
        }

        // Otherwise show all live `.ok` items sorted by urgency (most urgent first)
        let liveItems = candidatesById.values
            .filter { !$0.0.isAuthExpired }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        if !liveItems.isEmpty {
            return liveItems
        }
        return candidatesById.values.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public var miniBarEntries: [MiniBarEntry] {
        var entries: [MiniBarEntry] = []
        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            entries.append(MiniBarEntry(id: pool.id, headroomPercent: w.headroomPercent, pace: w.paceStatus, isError: false))
        }
        let allStandalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in allStandalone where snap.status != .unconfigured {
            if snap.status == .authExpired || snap.status == .incident {
                entries.append(MiniBarEntry(id: snap.id, headroomPercent: 0, pace: .burningFast, isError: true))
            } else if let primary = snap.primaryWindow {
                entries.append(MiniBarEntry(id: snap.id, headroomPercent: primary.headroomPercent, pace: primary.paceStatus, isError: false))
            }
        }
        return Array(entries.prefix(6))
    }
}
