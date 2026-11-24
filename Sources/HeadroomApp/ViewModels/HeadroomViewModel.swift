import Foundation
import SwiftUI
import AppKit
import HeadroomCore

public struct UrgentMenuItem: Sendable {
    public let label: String
    public let shortCode: String
    public let headroomPercent: Double
    public let pace: PaceStatus
    public let isAuthExpired: Bool
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
    public var selectedSettingsProvider: ProviderID = .claude
    public var credentialSummaryByProvider: [ProviderID: String] = [:]

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
        refreshCredentialSummaries()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.notifications.requestAuthorizationIfAvailable()
            self.config = await self.engine.loadConfig()
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
        var map: [ProviderID: String] = [:]
        for provider in ProviderID.allCases {
            let label = config.accounts.first(where: { $0.provider == provider })?.label ?? "personal"
            let creds = discovery.discover(for: provider, accountLabel: label)
            if creds.isEmpty {
                map[provider] = "Not connected"
            } else {
                map[provider] = creds.map(\.source).joined(separator: ", ")
            }
        }
        credentialSummaryByProvider = map
    }

    public func toggleDemoMode() {
        demoMode.toggle()
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
        Task {
            try? await engine.saveConfig(updated)
            if !demoMode {
                await refresh(force: false)
            }
        }
    }

    public func saveCredential(
        value: String,
        provider: ProviderID,
        accountLabel: String,
        kind: CredentialKind
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Credential cannot be empty." }
        do {
            try keychain.setSecret(trimmed, provider: provider, accountLabel: accountLabel, kind: kind)
            refreshCredentialSummaries()
            Task { await refresh(force: true) }
            return "Saved \(kind.rawValue) in Keychain for \(provider.displayName) (\(accountLabel))."
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

    public func openSettings(for provider: ProviderID? = nil) {
        if let provider {
            selectedSettingsProvider = provider
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - Derived View Collections

    public var standaloneSnapshots: [ProviderSnapshot] {
        PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
    }

    /// Providers with live quota data, local telemetry, or actionable errors.
    public var activeSnapshots: [ProviderSnapshot] {
        standaloneSnapshots
            .filter { $0.status != .unconfigured }
            .sorted { lhs, rhs in
                // Prioritize live windows with data over stale/telemetry-only rows
                let lhsRank = sortRank(lhs)
                let rhsRank = sortRank(rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                if lhs.urgencyScore != rhs.urgencyScore { return lhs.urgencyScore > rhs.urgencyScore }
                return lhs.provider.displayName < rhs.provider.displayName
            }
    }

    /// Providers that have not been connected yet (rendered compactly at bottom).
    public var unconfiguredSnapshots: [ProviderSnapshot] {
        standaloneSnapshots
            .filter { $0.status == .unconfigured }
            .sorted { $0.provider.displayName < $1.provider.displayName }
    }

    private func sortRank(_ snap: ProviderSnapshot) -> Int {
        switch snap.status {
        case .ok: return snap.windows.isEmpty ? 1 : 3
        case .authExpired, .incident: return 2
        case .stale: return snap.windows.isEmpty ? 1 : 2
        case .unconfigured: return 0
        }
    }

    /// Relative updated label for the popover header (replaces debug poll jargon).
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

    /// Quick-glance summary: which live provider currently has the most headroom.
    public var bestAvailableSummary: (name: String, headroom: Int)? {
        var best: (String, Double)?
        for pool in state.sharedPools {
            let h = pool.canonicalWindow.headroomPercent
            if best == nil || h > best!.1 { best = ("X Pool", h) }
        }
        for snap in standaloneSnapshots where snap.status == .ok {
            if let primary = snap.primaryWindow {
                let h = primary.headroomPercent
                if best == nil || h > best!.1 { best = (snap.provider.displayName, h) }
            }
        }
        guard let best else { return nil }
        return (best.0, Int(best.1.rounded()))
    }

    /// Soonest upcoming reset across all live windows (preferring constrained windows first).
    public var nextResetSummary: (label: String, countdown: String)? {
        let now = Date()
        var candidates: [(label: String, date: Date, used: Double)] = []
        for pool in state.sharedPools {
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
        // Prefer the soonest reset among windows that have usage > 0, else soonest overall
        let usedOnes = candidates.filter { $0.used > 0 }
        let poolToSearch = usedOnes.isEmpty ? candidates : usedOnes
        guard let soonest = poolToSearch.min(by: { $0.date < $1.date }) else { return nil }
        return (soonest.label, PaceCalculator.formatCountdown(until: soonest.date, now: now))
    }

    /// Most urgent live quota item for the menu bar.
    /// Strictly prefers live `.ok` windows so stale local-only telemetry never hijacks the menu bar.
    public var mostUrgentItem: UrgentMenuItem? {
        var liveCandidates: [(UrgentMenuItem, Double)] = []

        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            liveCandidates.append((
                UrgentMenuItem(label: pool.label, shortCode: "X", headroomPercent: w.headroomPercent, pace: w.paceStatus, isAuthExpired: false),
                PaceCalculator.windowUrgency(w)
            ))
        }

        for snap in standaloneSnapshots where snap.status == .ok {
            if let primary = snap.primaryWindow {
                liveCandidates.append((
                    UrgentMenuItem(
                        label: snap.provider.displayName,
                        shortCode: snap.provider.shortCode,
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

        // Only surface authExpired in the menu bar if no live windows exist at all
        if let expired = standaloneSnapshots.first(where: { $0.status == .authExpired }) {
            return UrgentMenuItem(
                label: expired.provider.displayName,
                shortCode: expired.provider.shortCode,
                headroomPercent: 0,
                pace: .burningFast,
                isAuthExpired: true
            )
        }
        return nil
    }

    /// Mini-bar entries for live tracked providers & shared pools.
    public var miniBarEntries: [MiniBarEntry] {
        var entries: [MiniBarEntry] = []
        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            entries.append(MiniBarEntry(id: pool.id, headroomPercent: w.headroomPercent, pace: w.paceStatus, isError: false))
        }
        for snap in activeSnapshots {
            if snap.status == .authExpired || snap.status == .incident {
                entries.append(MiniBarEntry(id: snap.id, headroomPercent: 0, pace: .burningFast, isError: true))
            } else if let primary = snap.primaryWindow {
                entries.append(MiniBarEntry(id: snap.id, headroomPercent: primary.headroomPercent, pace: primary.paceStatus, isError: false))
            }
        }
        return Array(entries.prefix(5))
    }

    /// True if more than one account label exists across configured accounts.
    public var hasMultipleAccounts: Bool {
        Set(config.accounts.map(\.label)).count > 1
    }
}
