import Foundation

public enum PaceCalculator {
    /// Evaluates burn rate / pace by comparing % of quota used against % of reset window elapsed.
    public static func evaluate(
        used: Double,
        limit: Double,
        resetsAt: Date?,
        windowDurationSec: Int?,
        now: Date = Date()
    ) -> PaceAnalysis {
        let usedPercent: Double = limit > 0 ? max(0, (used / limit) * 100.0) : 0
        let headroomPercent = max(0, 100.0 - usedPercent)

        guard let resetsAt, let durationSec = windowDurationSec, durationSec > 0 else {
            let status: PaceStatus
            if usedPercent >= 85.0 {
                status = .burningFast
            } else if usedPercent <= 40.0 {
                status = .reserve
            } else {
                status = .onTrack
            }
            return PaceAnalysis(
                usedPercent: round2(usedPercent),
                headroomPercent: round2(headroomPercent),
                elapsedPercent: 0,
                paceDeltaPercent: round2(usedPercent),
                burnRateMultiplier: nil,
                projectedPercentAtReset: nil,
                projectedExhaustionAt: nil,
                willExhaustBeforeReset: usedPercent >= 100.0,
                paceStatus: status
            )
        }

        let duration = Double(durationSec)
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        let elapsed = min(duration, max(0, duration - remaining))
        let elapsedPercent = (elapsed / duration) * 100.0
        let paceDelta = usedPercent - elapsedPercent

        var burnRateMultiplier: Double?
        var projectedAtReset: Double?
        var projectedExhaustionAt: Date?
        var willExhaustBeforeReset = usedPercent >= 100.0

        // Require at least 3% of the window elapsed to avoid early-window projection spikes,
        // unless usage is already substantial (>= 20%).
        if elapsedPercent >= 3.0 || usedPercent >= 20.0 {
            let safeElapsedPct = max(elapsedPercent, 1.0)
            let ratio = usedPercent / safeElapsedPct
            burnRateMultiplier = round2(ratio)
            let projected = ratio * 100.0
            projectedAtReset = round2(projected)

            if usedPercent >= 100.0 {
                projectedExhaustionAt = now
                willExhaustBeforeReset = true
            } else if usedPercent > 0 && elapsed > 0 && projected > 100.0 {
                let ratePerSec = usedPercent / elapsed
                let secLeft = (100.0 - usedPercent) / ratePerSec
                let exhaustionDate = now.addingTimeInterval(secLeft)
                projectedExhaustionAt = exhaustionDate
                willExhaustBeforeReset = exhaustionDate < resetsAt
            }
        }

        let status: PaceStatus
        if usedPercent >= 90.0 {
            status = .burningFast
        } else if elapsedPercent < 5.0 {
            if usedPercent >= 20.0 {
                status = .burningFast
            } else if usedPercent <= 5.0 {
                status = .reserve
            } else {
                status = .onTrack
            }
        } else if paceDelta >= 10.0 || (projectedAtReset ?? 0) >= 115.0 {
            status = .burningFast
        } else if paceDelta <= -8.0 || (usedPercent < 5.0 && elapsedPercent >= 10.0) {
            status = .reserve
        } else {
            status = .onTrack
        }

        return PaceAnalysis(
            usedPercent: round2(usedPercent),
            headroomPercent: round2(headroomPercent),
            elapsedPercent: round2(elapsedPercent),
            paceDeltaPercent: round2(paceDelta),
            burnRateMultiplier: burnRateMultiplier,
            projectedPercentAtReset: projectedAtReset,
            projectedExhaustionAt: projectedExhaustionAt,
            willExhaustBeforeReset: willExhaustBeforeReset,
            paceStatus: status
        )
    }

    /// Higher score = more urgent to surface in menu bar and top of popover.
    public static func windowUrgency(_ window: QuotaWindow) -> Double {
        let base = min(window.usedPercent, 120.0)
        let paceBonus: Double
        switch window.paceStatus {
        case .burningFast: paceBonus = 22.0
        case .onTrack: paceBonus = 6.0
        case .reserve: paceBonus = 0.0
        }
        let exhaustionBonus: Double = (window.paceDetail?.willExhaustBeforeReset == true) ? 15.0 : 0.0
        return base + paceBonus + exhaustionBonus
    }

    public static func snapshotUrgency(_ snapshot: ProviderSnapshot) -> Double {
        let topWindowScore = snapshot.windows.map { windowUrgency($0) }.max() ?? 0
        switch snapshot.status {
        case .ok:
            return topWindowScore
        case .stale:
            return max(topWindowScore, 20.0)
        case .authExpired:
            return max(topWindowScore, 75.0)
        case .incident:
            return max(topWindowScore, 80.0)
        case .unconfigured:
            return -10.0
        }
    }

    public static func formatCountdown(until date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 {
            return "Resetting"
        }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "<1m"
        }
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}
