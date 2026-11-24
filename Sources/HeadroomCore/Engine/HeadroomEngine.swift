import Foundation

public struct PollResult: Sendable {
    public let state: HeadroomState
    public let alerts: [HeadroomAlert]

    public init(state: HeadroomState, alerts: [HeadroomAlert]) {
        self.state = state
        self.alerts = alerts
    }
}

public actor HeadroomEngine {
    private let adapters: [ProviderID: any ProviderAdapter]
    private let context: AdapterContext
    private let stateStore: StateStore
    private let configStore: ConfigStore
    private let poller: AdaptivePoller
    private let alertEvaluator: AlertEvaluator
    private var cachedState: HeadroomState?

    public init(
        adapters: [any ProviderAdapter] = HeadroomEngine.defaultAdapters(),
        context: AdapterContext = AdapterContext(),
        stateStore: StateStore = StateStore(),
        configStore: ConfigStore = ConfigStore(),
        poller: AdaptivePoller? = nil,
        alertEvaluator: AlertEvaluator? = nil
    ) {
        var map: [ProviderID: any ProviderAdapter] = [:]
        for adapter in adapters {
            map[adapter.provider] = adapter
        }
        self.adapters = map
        self.context = context
        self.stateStore = stateStore
        self.configStore = configStore
        self.poller = poller ?? AdaptivePoller()
        self.alertEvaluator = alertEvaluator ?? AlertEvaluator()
    }

    public static func defaultAdapters() -> [any ProviderAdapter] {
        [
            ClaudeAdapter(),
            CodexAdapter(),
            GeminiAdapter(),
            GrokAdapter(),
            CursorAdapter()
        ]
    }

    public func loadConfig() async -> HeadroomConfig {
        await configStore.load()
    }

    public func saveConfig(_ config: HeadroomConfig) async throws {
        try await configStore.save(config)
        await alertEvaluator.updateConfig(config.alerts)
    }

    public func loadCachedState() async -> HeadroomState? {
        if let cachedState {
            return applyStaleness(to: cachedState, config: await configStore.load())
        }
        if let loaded = await stateStore.load() {
            cachedState = loaded
            return applyStaleness(to: loaded, config: await configStore.load())
        }
        return nil
    }

    /// Concurrently polls enabled provider accounts with independent error/backoff isolation,
    /// deduplicates shared pools, persists atomic JSON cache, and evaluates alerts.
    public func poll(
        providers filterProviders: Set<ProviderID>? = nil,
        force: Bool = false
    ) async -> PollResult {
        let now = context.now()
        let config = await configStore.load()
        await alertEvaluator.updateConfig(config.alerts)
        let previousState = await loadCachedState()
        let prevSnapshotsById = Dictionary(uniqueKeysWithValues: (previousState?.snapshots ?? []).map { ($0.id, $0) })

        let enabledAccounts = config.accounts.filter { account in
            guard account.enabled else { return false }
            if let filterProviders, !filterProviders.contains(account.provider) {
                return false
            }
            return true
        }

        // Determine which accounts should be polled vs kept cached due to backoff
        var accountsToPoll: [AccountConfig] = []
        var retainedSnapshots: [ProviderSnapshot] = []

        // Keep snapshots for providers excluded by filter
        if let filterProviders {
            for snap in previousState?.snapshots ?? [] where !filterProviders.contains(snap.provider) {
                retainedSnapshots.append(snap)
            }
        }

        for account in enabledAccounts {
            let key = account.id
            if await poller.shouldPoll(accountKey: key, now: now, force: force) {
                accountsToPoll.append(account)
            } else if let prev = prevSnapshotsById[key] {
                retainedSnapshots.append(markStaleIfNeeded(prev, now: now, staleAfterSec: config.polling.staleAfterSec))
            } else {
                accountsToPoll.append(account)
            }
        }

        // Concurrent provider fetch via TaskGroup (isolated per provider)
        let adapterMap = self.adapters
        let ctx = self.context
        let fetchedSnapshots: [ProviderSnapshot] = await withTaskGroup(of: ProviderSnapshot.self) { group in
            for account in accountsToPoll {
                guard let adapter = adapterMap[account.provider] else { continue }
                group.addTask {
                    await adapter.fetchUsage(account: account, context: ctx)
                }
            }
            var collected: [ProviderSnapshot] = []
            for await snap in group {
                collected.append(snap)
            }
            return collected
        }

        // Record backoff outcomes & merge with previous windows on transient incident so user retains stale telemetry
        var mergedSnapshots: [ProviderSnapshot] = retainedSnapshots
        for snap in fetchedSnapshots {
            await poller.recordOutcome(accountKey: snap.id, status: snap.status, now: now)
            if snap.status == .incident, let prev = prevSnapshotsById[snap.id], !prev.windows.isEmpty {
                let degraded = ProviderSnapshot(
                    provider: snap.provider,
                    accountLabel: snap.accountLabel,
                    status: .stale,
                    windows: prev.windows,
                    fetchedAt: prev.fetchedAt,
                    source: prev.source,
                    billingModel: prev.billingModel,
                    message: snap.message,
                    estimatedLocalCostUSD: prev.estimatedLocalCostUSD
                )
                mergedSnapshots.append(degraded)
            } else {
                mergedSnapshots.append(snap)
            }
        }

        // Sort deterministically by urgency descending, then provider name
        mergedSnapshots.sort { lhs, rhs in
            if lhs.urgencyScore != rhs.urgencyScore {
                return lhs.urgencyScore > rhs.urgencyScore
            }
            return lhs.id < rhs.id
        }

        let sharedPools = config.deduplicateSharedPools
            ? PoolDeduplicator.buildSharedPools(from: mergedSnapshots)
            : []

        let newState = HeadroomState(
            schemaVersion: 1,
            updatedAt: now,
            snapshots: mergedSnapshots,
            sharedPools: sharedPools
        )

        cachedState = newState
        try? await stateStore.save(newState)

        let alerts = await alertEvaluator.evaluate(previous: previousState, current: newState, now: now)
        return PollResult(state: newState, alerts: alerts)
    }

    public func nextRecommendedInterval() async -> TimeInterval {
        await poller.recommendedInterval(now: context.now())
    }

    public func isUserActive() async -> Bool {
        await poller.isActive(now: context.now())
    }

    public func resetBackoff(for accountKey: String? = nil) async {
        await poller.resetBackoff(accountKey: accountKey)
    }

    private func applyStaleness(to state: HeadroomState, config: HeadroomConfig) -> HeadroomState {
        let now = context.now()
        let updated = state.snapshots.map { markStaleIfNeeded($0, now: now, staleAfterSec: config.polling.staleAfterSec) }
        return HeadroomState(
            schemaVersion: state.schemaVersion,
            updatedAt: state.updatedAt,
            snapshots: updated,
            sharedPools: state.sharedPools
        )
    }

    private func markStaleIfNeeded(_ snapshot: ProviderSnapshot, now: Date, staleAfterSec: Int) -> ProviderSnapshot {
        guard snapshot.status == .ok else { return snapshot }
        if now.timeIntervalSince(snapshot.fetchedAt) > TimeInterval(staleAfterSec) {
            return ProviderSnapshot(
                provider: snapshot.provider,
                accountLabel: snapshot.accountLabel,
                status: .stale,
                windows: snapshot.windows,
                fetchedAt: snapshot.fetchedAt,
                source: snapshot.source,
                billingModel: snapshot.billingModel,
                message: "Cached snapshot is older than \(staleAfterSec / 60)m.",
                estimatedLocalCostUSD: snapshot.estimatedLocalCostUSD
            )
        }
        return snapshot
    }
}

/// Realistic demo snapshot generator showcasing all 5 providers, pace math,
/// and unified X Subscription (Cursor + Grok) shared pool deduplication.
public enum DemoFixtures {
    public static func makeDemoState(now: Date = Date()) -> HeadroomState {
        let claude = ProviderSnapshot(
            provider: .claude,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(
                    id: "session_5h",
                    label: "5h Session",
                    unit: .percent,
                    used: 64.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(3 * 3600 + 25 * 60),
                    windowDurationSec: 18000,
                    now: now
                ),
                QuotaWindow(
                    id: "weekly_7d",
                    label: "Weekly Cap",
                    unit: .percent,
                    used: 41.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(3 * 86400 + 6 * 3600),
                    windowDurationSec: 604800,
                    now: now
                )
            ],
            fetchedAt: now,
            source: "demo:claude.ai",
            billingModel: .subscription,
            estimatedLocalCostUSD: 14.20
        )

        let codex = ProviderSnapshot(
            provider: .codex,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(
                    id: "session_5h",
                    label: "5h Session",
                    unit: .percent,
                    used: 84.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60),
                    windowDurationSec: 18000,
                    now: now
                ),
                QuotaWindow(
                    id: "weekly_7d",
                    label: "Weekly Cap",
                    unit: .percent,
                    used: 52.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(4 * 86400),
                    windowDurationSec: 604800,
                    now: now
                )
            ],
            fetchedAt: now,
            source: "demo:~/.codex/auth.json",
            billingModel: .subscription,
            estimatedLocalCostUSD: 9.85
        )

        let cursor = ProviderSnapshot(
            provider: .cursor,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(
                    id: "x_weekly_pool",
                    label: "X Weekly Pool (Shared)",
                    unit: .percent,
                    used: 48.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(3 * 86400 + 14 * 3600),
                    windowDurationSec: 604800,
                    sharedPoolId: CursorAdapter.xSubscriptionPoolID,
                    now: now
                ),
                QuotaWindow(
                    id: "third_party_spend",
                    label: "3rd-Party API Cap",
                    unit: .dollars,
                    used: 18.50,
                    limit: 50.0,
                    resetsAt: now.addingTimeInterval(14 * 86400),
                    windowDurationSec: 2_592_000,
                    now: now
                )
            ],
            fetchedAt: now,
            source: "demo:cursor-sand",
            billingModel: .xSubscriptionUnified,
            message: "Unified X Subscription active (shared weekly pool with Grok)."
        )

        let grok = ProviderSnapshot(
            provider: .grok,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(
                    id: "x_weekly_pool",
                    label: "X Weekly Pool (Shared)",
                    unit: .percent,
                    used: 48.0,
                    limit: 100.0,
                    resetsAt: now.addingTimeInterval(3 * 86400 + 14 * 3600),
                    windowDurationSec: 604800,
                    sharedPoolId: GrokAdapter.xSubscriptionPoolID,
                    now: now
                ),
                QuotaWindow(
                    id: "xai_api_credits",
                    label: "xAI Prepaid Credits",
                    unit: .dollars,
                    used: 6.40,
                    limit: 25.0,
                    resetsAt: nil,
                    windowDurationSec: nil,
                    now: now
                )
            ],
            fetchedAt: now,
            source: "demo:grok.com/dashboard + api.x.ai",
            billingModel: .hybrid
        )

        let gemini = ProviderSnapshot(
            provider: .gemini,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(
                    id: "daily_requests",
                    label: "Daily Requests (CLI)",
                    unit: .requests,
                    used: 215,
                    limit: 1000,
                    resetsAt: now.addingTimeInterval(9 * 3600 + 30 * 60),
                    windowDurationSec: 86400,
                    now: now
                )
            ],
            fetchedAt: now,
            source: "demo:lane:cli",
            billingModel: .subscription,
            estimatedLocalCostUSD: 2.15
        )

        let snapshots = [codex, claude, cursor, grok, gemini].sorted { $0.urgencyScore > $1.urgencyScore }
        let sharedPools = PoolDeduplicator.buildSharedPools(from: snapshots)
        return HeadroomState(schemaVersion: 1, updatedAt: now, snapshots: snapshots, sharedPools: sharedPools)
    }
}
