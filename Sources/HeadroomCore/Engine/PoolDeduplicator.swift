import Foundation

public enum PoolDeduplicator {
    /// Detects providers that draw from the same shared pool (e.g., Cursor + Grok under
    /// unified X Subscription) and produces deduplicated SharedPoolGroup entries so the
    /// UI and summaries never double-count the same weekly allowance.
    public static func buildSharedPools(from snapshots: [ProviderSnapshot]) -> [SharedPoolGroup] {
        // Group by (sharedPoolId, accountLabel)
        struct PoolKey: Hashable {
            let poolId: String
            let accountLabel: String
        }

        var buckets: [PoolKey: [(ProviderSnapshot, QuotaWindow)]] = [:]

        for snapshot in snapshots where snapshot.status != .unconfigured {
            for window in snapshot.windows {
                if let poolId = window.sharedPoolId, !poolId.isEmpty {
                    let key = PoolKey(poolId: poolId, accountLabel: snapshot.accountLabel)
                    buckets[key, default: []].append((snapshot, window))
                }
            }
        }

        var groups: [SharedPoolGroup] = []

        for (key, entries) in buckets {
            let uniqueProviders = Array(Set(entries.map { $0.0.provider })).sorted { $0.rawValue < $1.rawValue }
            // Only form a linked shared pool when 2+ distinct providers share the pool
            guard uniqueProviders.count >= 2 else { continue }

            // Pick the freshest non-stale window as canonical (break ties by higher usedPercent for conservative headroom)
            let bestEntry = entries.max { lhs, rhs in
                let lhsOk = lhs.0.status == .ok ? 1 : 0
                let rhsOk = rhs.0.status == .ok ? 1 : 0
                if lhsOk != rhsOk { return lhsOk < rhsOk }
                if lhs.0.fetchedAt != rhs.0.fetchedAt { return lhs.0.fetchedAt < rhs.0.fetchedAt }
                return lhs.1.usedPercent < rhs.1.usedPercent
            }!

            // Collect non-shared supplementary windows from member providers (e.g. Cursor 3rd-party API cap, Grok xAI prepaid credits)
            var supplementary: [SupplementaryPoolWindow] = []
            let memberSet = Set(uniqueProviders)
            for snapshot in snapshots where snapshot.accountLabel == key.accountLabel && memberSet.contains(snapshot.provider) {
                for window in snapshot.windows where window.sharedPoolId != key.poolId {
                    supplementary.append(SupplementaryPoolWindow(provider: snapshot.provider, window: window))
                }
            }

            let groupLabel: String
            if key.poolId == CursorAdapter.xSubscriptionPoolID {
                groupLabel = "X Subscription Weekly Pool"
            } else {
                groupLabel = bestEntry.1.label
            }

            groups.append(SharedPoolGroup(
                id: "\(key.poolId):\(key.accountLabel)",
                label: groupLabel,
                accountLabel: key.accountLabel,
                memberProviders: uniqueProviders,
                canonicalWindow: bestEntry.1,
                supplementaryWindows: supplementary
            ))
        }

        return groups.sorted { $0.id < $1.id }
    }

    /// Returns standalone snapshots excluding providers already folded into a SharedPoolGroup.
    public static func standaloneSnapshots(
        from snapshots: [ProviderSnapshot],
        sharedPools: [SharedPoolGroup]
    ) -> [ProviderSnapshot] {
        struct AccountProviderKey: Hashable {
            let provider: ProviderID
            let accountLabel: String
        }
        var groupedKeys: Set<AccountProviderKey> = []
        for pool in sharedPools {
            for provider in pool.memberProviders {
                groupedKeys.insert(AccountProviderKey(provider: provider, accountLabel: pool.accountLabel))
            }
        }
        return snapshots.filter {
            !groupedKeys.contains(AccountProviderKey(provider: $0.provider, accountLabel: $0.accountLabel))
        }
    }
}
