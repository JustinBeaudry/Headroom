import Foundation
import CoreGraphics

public protocol ActivityDetecting: Sendable {
    /// Returns seconds since last local developer/system activity (CLI log writes or HID input).
    func secondsSinceLastActivity(now: Date) -> TimeInterval
}

public final class MacOSActivityDetector: ActivityDetecting, Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func secondsSinceLastActivity(now: Date = Date()) -> TimeInterval {
        var minIdle = TimeInterval.greatestFiniteMagnitude

        // 1. Check macOS HID idle time (keyboard/mouse activity)
        let hidIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        if hidIdle >= 0 {
            minIdle = min(minIdle, hidIdle)
        }

        // 2. Check recent modification dates in local AI CLI/editor directories
        let watchedPaths = [
            ".claude/projects",
            ".codex/sessions",
            ".gemini/tmp",
            ".gemini/sessions",
            "Library/Application Support/Cursor/User/globalStorage"
        ]
        let fm = FileManager.default
        for rel in watchedPaths {
            let url = homeDirectory.appendingPathComponent(rel)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date {
                let delta = max(0, now.timeIntervalSince(mtime))
                minIdle = min(minIdle, delta)
            }
        }

        return minIdle.isFinite ? minIdle : 0
    }
}

public struct ProviderBackoffState: Sendable, Hashable {
    public var consecutiveFailures: Int
    public var nextAllowedPollAt: Date

    public init(consecutiveFailures: Int = 0, nextAllowedPollAt: Date = .distantPast) {
        self.consecutiveFailures = consecutiveFailures
        self.nextAllowedPollAt = nextAllowedPollAt
    }
}

/// Manages adaptive polling intervals (fast when active, slow when idle) and
/// independent per-provider exponential backoff on transient failures.
public actor AdaptivePoller {
    private let config: PollingConfig
    private let activityDetector: any ActivityDetecting
    private var backoffs: [String: ProviderBackoffState] = [:]

    public init(
        config: PollingConfig = PollingConfig(),
        activityDetector: any ActivityDetecting = MacOSActivityDetector()
    ) {
        self.config = config
        self.activityDetector = activityDetector
    }

    public func recommendedInterval(now: Date = Date()) -> TimeInterval {
        let idleSec = activityDetector.secondsSinceLastActivity(now: now)
        if idleSec <= TimeInterval(config.idleThresholdSec) {
            return TimeInterval(max(30, config.activeIntervalSec))
        }
        return TimeInterval(max(config.activeIntervalSec, config.idleIntervalSec))
    }

    public func isActive(now: Date = Date()) -> Bool {
        activityDetector.secondsSinceLastActivity(now: now) <= TimeInterval(config.idleThresholdSec)
    }

    public func shouldPoll(accountKey: String, now: Date = Date(), force: Bool = false) -> Bool {
        if force { return true }
        guard let state = backoffs[accountKey] else { return true }
        return now >= state.nextAllowedPollAt
    }

    public func recordOutcome(accountKey: String, status: SnapshotStatus, now: Date = Date()) {
        switch status {
        case .ok, .unconfigured:
            backoffs.removeValue(forKey: accountKey)
        case .stale, .authExpired, .incident:
            var state = backoffs[accountKey] ?? ProviderBackoffState()
            state.consecutiveFailures += 1
            let base = Double(max(60, config.activeIntervalSec))
            let exponent = min(Double(state.consecutiveFailures - 1), 6.0)
            let delay = min(Double(config.maxBackoffSec), base * pow(2.0, exponent))
            state.nextAllowedPollAt = now.addingTimeInterval(delay)
            backoffs[accountKey] = state
        }
    }

    public func resetBackoff(accountKey: String? = nil) {
        if let accountKey {
            backoffs.removeValue(forKey: accountKey)
        } else {
            backoffs.removeAll()
        }
    }

    public func backoffState(for accountKey: String) -> ProviderBackoffState? {
        backoffs[accountKey]
    }
}
