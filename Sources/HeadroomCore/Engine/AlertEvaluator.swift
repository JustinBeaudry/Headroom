import Foundation

public enum HeadroomAlertKind: String, Codable, Sendable, Hashable {
    case lowHeadroom = "low_headroom"
    case projectedExhaustion = "projected_exhaustion"
    case windowReset = "window_reset"
    case authExpired = "auth_expired"
}

public struct HeadroomAlert: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: HeadroomAlertKind
    public let provider: ProviderID
    public let accountLabel: String
    public let windowId: String?
    public let title: String
    public let body: String
    public let triggeredAt: Date

    public init(
        id: String,
        kind: HeadroomAlertKind,
        provider: ProviderID,
        accountLabel: String,
        windowId: String? = nil,
        title: String,
        body: String,
        triggeredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.accountLabel = accountLabel
        self.windowId = windowId
        self.title = title
        self.body = body
        self.triggeredAt = triggeredAt
    }
}

public struct AlertHistory: Codable, Sendable {
    public var lastFiredAt: [String: Date]

    public init(lastFiredAt: [String: Date] = [:]) {
        self.lastFiredAt = lastFiredAt
    }
}

public actor AlertEvaluator {
    private var config: AlertConfig
    private let historyURL: URL?
    private var history: AlertHistory

    public init(config: AlertConfig = AlertConfig(), historyURL: URL? = HeadroomPaths.alertStateFileURL) {
        self.config = config
        self.historyURL = historyURL
        if let historyURL,
           let data = try? Data(contentsOf: historyURL),
           let decoded = try? HeadroomJSON.makeDecoder().decode(AlertHistory.self, from: data) {
            self.history = decoded
        } else {
            self.history = AlertHistory()
        }
    }

    public func updateConfig(_ newConfig: AlertConfig) {
        self.config = newConfig
    }

    public func evaluate(
        previous: HeadroomState?,
        current: HeadroomState,
        now: Date = Date()
    ) -> [HeadroomAlert] {
        guard config.enabled else { return [] }

        var alerts: [HeadroomAlert] = []
        let prevMap = Dictionary(uniqueKeysWithValues: (previous?.snapshots ?? []).map { ($0.id, $0) })

        for snapshot in current.snapshots {
            let prev = prevMap[snapshot.id]

            // 1. Auth expired transition
            if config.notifyAuthExpired,
               snapshot.status == .authExpired,
               prev?.status != .authExpired {
                let dedupKey = "auth:\(snapshot.id)"
                if canFire(key: dedupKey, now: now) {
                    alerts.append(HeadroomAlert(
                        id: "\(dedupKey):\(Int(now.timeIntervalSince1970))",
                        kind: .authExpired,
                        provider: snapshot.provider,
                        accountLabel: snapshot.accountLabel,
                        title: "\(snapshot.provider.displayName) session expired",
                        body: snapshot.message ?? "Re-authenticate to resume live headroom tracking.",
                        triggeredAt: now
                    ))
                    markFired(key: dedupKey, now: now)
                }
            }

            let prevWindows = Dictionary(uniqueKeysWithValues: (prev?.windows ?? []).map { ($0.id, $0) })

            for window in snapshot.windows {
                let prevWindow = prevWindows[window.id]

                // 2. Window reset detected (usage dropped sharply or reset timestamp moved forward)
                if config.notifyWindowReset, let prevWindow {
                    let droppedSharply = prevWindow.usedPercent >= 40.0 && window.usedPercent <= 10.0
                    let resetAdvanced: Bool = {
                        if let oldReset = prevWindow.resetsAt, let newReset = window.resetsAt {
                            return newReset.timeIntervalSince(oldReset) > 600 && prevWindow.usedPercent >= 25.0 && window.usedPercent < prevWindow.usedPercent
                        }
                        return false
                    }()
                    if droppedSharply || resetAdvanced {
                        let dedupKey = "reset:\(snapshot.id):\(window.id)"
                        if canFire(key: dedupKey, now: now, overrideCooldown: 600) {
                            alerts.append(HeadroomAlert(
                                id: "\(dedupKey):\(Int(now.timeIntervalSince1970))",
                                kind: .windowReset,
                                provider: snapshot.provider,
                                accountLabel: snapshot.accountLabel,
                                windowId: window.id,
                                title: "\(snapshot.provider.displayName) \(window.label) reset",
                                body: String(format: "Fresh headroom available (%.0f%% remaining).", window.headroomPercent),
                                triggeredAt: now
                            ))
                            markFired(key: dedupKey, now: now)
                        }
                    }
                }

                // 3. Low headroom threshold (default <= 20% left)
                if window.headroomPercent <= config.lowHeadroomThresholdPercent {
                    let dedupKey = "low:\(snapshot.id):\(window.id)"
                    if canFire(key: dedupKey, now: now) {
                        let countdown = PaceCalculator.formatCountdown(until: window.resetsAt, now: now)
                        alerts.append(HeadroomAlert(
                            id: "\(dedupKey):\(Int(now.timeIntervalSince1970))",
                            kind: .lowHeadroom,
                            provider: snapshot.provider,
                            accountLabel: snapshot.accountLabel,
                            windowId: window.id,
                            title: "\(snapshot.provider.displayName) low headroom (\(Int(window.headroomPercent.rounded()))% left)",
                            body: "\(window.label) is at \(window.formattedUsage). Resets in \(countdown).",
                            triggeredAt: now
                        ))
                        markFired(key: dedupKey, now: now)
                    }
                }

                // 4. Projected exhaustion before reset
                if config.notifyProjectedExhaustion,
                   window.paceStatus == .burningFast,
                   let detail = window.paceDetail,
                   detail.willExhaustBeforeReset,
                   let exhaustDate = detail.projectedExhaustionAt,
                   window.headroomPercent > 0 {
                    let dedupKey = "burn:\(snapshot.id):\(window.id)"
                    if canFire(key: dedupKey, now: now) {
                        let eta = PaceCalculator.formatCountdown(until: exhaustDate, now: now)
                        let resetEta = PaceCalculator.formatCountdown(until: window.resetsAt, now: now)
                        alerts.append(HeadroomAlert(
                            id: "\(dedupKey):\(Int(now.timeIntervalSince1970))",
                            kind: .projectedExhaustion,
                            provider: snapshot.provider,
                            accountLabel: snapshot.accountLabel,
                            windowId: window.id,
                            title: "\(snapshot.provider.displayName) burning fast",
                            body: "\(window.label) projected to run out in ~\(eta) (before reset in \(resetEta)).",
                            triggeredAt: now
                        ))
                        markFired(key: dedupKey, now: now)
                    }
                }
            }
        }

        if !alerts.isEmpty {
            persistHistory()
        }

        return alerts
    }

    private func canFire(key: String, now: Date, overrideCooldown: Int? = nil) -> Bool {
        guard let last = history.lastFiredAt[key] else { return true }
        let cooldown = TimeInterval(overrideCooldown ?? config.cooldownSec)
        return now.timeIntervalSince(last) >= cooldown
    }

    private func markFired(key: String, now: Date) {
        history.lastFiredAt[key] = now
    }

    private func persistHistory() {
        guard let historyURL else { return }
        do {
            let dir = historyURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try HeadroomJSON.makeEncoder(prettyPrinted: false).encode(history)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            // Non-fatal
        }
    }
}
