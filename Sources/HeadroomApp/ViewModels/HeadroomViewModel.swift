import Foundation
import SwiftUI
import AppKit
import HeadroomCore

@MainActor
@Observable
public final class HeadroomViewModel {
    public var state: HeadroomState = HeadroomState(snapshots: [])
    public var config: HeadroomConfig = HeadroomConfig()
    public var isRefreshing: Bool = false
    public var privacyMode: Bool = false
    public var demoMode: Bool = false
    public var lastAlerts: [HeadroomAlert] = []
    public var isActivePolling: Bool = true
    public var nextPollSeconds: Int = 90
    public var statusMessage: String?

    private let engine: HeadroomEngine
    private let keychain: KeychainStore
    private let notifications: NotificationManager
    private var pollingTask: Task<Void, Never>?

    public init(
        engine: HeadroomEngine = HeadroomEngine(),
        keychain: KeychainStore = KeychainStore(),
        notifications: NotificationManager = NotificationManager()
    ) {
        self.engine = engine
        self.keychain = keychain
        self.notifications = notifications
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.notifications.requestAuthorizationIfAvailable()
            self.config = await self.engine.loadConfig()
            if let cached = await self.engine.loadCachedState() {
                self.state = cached
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
            statusMessage = "Showing Demo Telemetry"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        if force {
            await engine.resetBackoff()
        }
        let result = await engine.poll(force: force)
        self.state = result.state
        self.isActivePolling = await engine.isUserActive()
        self.nextPollSeconds = Int(await engine.nextRecommendedInterval())
        if !result.alerts.isEmpty {
            self.lastAlerts = Array((result.alerts + self.lastAlerts).prefix(10))
            notifications.deliver(result.alerts)
        }
        statusMessage = nil
    }

    public func toggleDemoMode() {
        demoMode.toggle()
        if demoMode {
            state = DemoFixtures.makeDemoState()
            statusMessage = "Demo Mode"
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
        Task { await refresh(force: true) }
    }

    public func openReauth(for provider: ProviderID) {
        if let url = provider.reauthURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Most urgent active window across standalone snapshots and shared pools.
    public var mostUrgentItem: (label: String, shortCode: String, headroomPercent: Double, pace: PaceStatus, isAuthExpired: Bool)? {
        var candidates: [(String, String, Double, PaceStatus, Bool, Double)] = []

        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            let score = PaceCalculator.windowUrgency(w)
            candidates.append((pool.label, "X", w.headroomPercent, w.paceStatus, false, score))
        }

        let standalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in standalone where snap.status != .unconfigured {
            if snap.status == .authExpired {
                candidates.append((snap.provider.displayName, snap.provider.shortCode, 0, .burningFast, true, snap.urgencyScore))
            } else if let primary = snap.primaryWindow {
                candidates.append((snap.provider.displayName, snap.provider.shortCode, primary.headroomPercent, primary.paceStatus, false, snap.urgencyScore))
            }
        }

        guard let top = candidates.max(by: { $0.5 < $1.5 }) else { return nil }
        return (top.0, top.1, top.2, top.3, top.4)
    }

    /// Mini-bar entries for all tracked providers (deduplicating unified X Subscription pool).
    public var miniBarEntries: [(id: String, headroomPercent: Double, pace: PaceStatus, isError: Bool)] {
        var entries: [(String, Double, PaceStatus, Bool)] = []
        for pool in state.sharedPools {
            let w = pool.canonicalWindow
            entries.append((pool.id, w.headroomPercent, w.paceStatus, false))
        }
        let standalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in standalone {
            if snap.status == .authExpired || snap.status == .incident {
                entries.append((snap.id, 0, .burningFast, true))
            } else if let primary = snap.primaryWindow {
                entries.append((snap.id, primary.headroomPercent, primary.paceStatus, false))
            } else {
                entries.append((snap.id, 100, .reserve, false))
            }
        }
        return Array(entries.prefix(5))
    }

    public var standaloneSnapshots: [ProviderSnapshot] {
        PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
    }
}
