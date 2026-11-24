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
    public var demoMode: Bool = false
    public var lastAlerts: [HeadroomAlert] = []
    public var isActivePolling: Bool = true
    public var nextPollSeconds: Int = 90
    public var selectedAccountFilter: String? = nil // nil = All accounts
    public var selectedSettingsProvider: ProviderID = .claude
    public var selectedSettingsAccountLabel: String = "personal"
    public var credentialSummaryByAccount: [String: String] = [:]

    private let engine: HeadroomEngine
    private let keychain: KeychainStore
    private let discovery: CredentialDiscovery
    private let notifications: NotificationManager
    private var pollingTask: Task<Void, Never>?

    public init(
        engine: HeadroomEngine = HeadroomEngine(),
        keychain: KeychainStore = KeychainStore(),
        notifications: NotificationManager = NotificationManager()
    ) {
        self.engine = engine
        self.keychain = keychain
        self.discovery = CredentialDiscovery(secretStore: keychain)
        self.notifications = notifications
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
                if !self.demoMode {
                    await self.refresh(force: false)
                }
            }
        }
    }

    public func refresh(force: Bool = true) async {
        if demoMode {
            state = DemoFixtures.makeDemoState()
            hasCompletedInitialLoad = true
            return
        }
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

    public func toggleDemoMode() {
        demoMode.toggle()
        selectedAccountFilter = nil
        if demoMode {
            state = DemoFixtures.makeDemoState()
            hasCompletedInitialLoad = true
        } else {
            Task { await refresh(force: true) }
        }
    }

    public func toggleDisplayMode() {
        config.menuBarDisplayMode = (config.menuBarDisplayMode == .mostUrgent) ? .miniBars : .mostUrgent
        saveConfigAsync()
    }

    public func saveConfigAsync() {
        let updated = config
        refreshCredentialSummaries()
        Task {
            try? await engine.saveConfig(updated)
            if !demoMode {
                await refresh(force: false)
            }
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
        if selectedAccountFilter == account.label && !availableAccountLabels.contains(account.label) {
            selectedAccountFilter = nil
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
        let fromConfig = demoMode ? Set<String>() : Set(config.accounts.filter(\.enabled).map(\.label))
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
        let countInConfig = demoMode ? 0 : Set(config.accounts.filter { $0.provider == provider && $0.enabled }.map(\.label)).count
        return max(countInState, countInConfig) > 1
    }

    public var filteredSharedPools: [SharedPoolGroup] {
        guard let filter = selectedAccountFilter else { return state.sharedPools }
        return state.sharedPools.filter { $0.accountLabel == filter }
    }

    public var standaloneSnapshots: [ProviderSnapshot] {
        let allStandalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        guard let filter = selectedAccountFilter else { return allStandalone }
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
        if demoMode {
            return "Demo telemetry"
        }
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
