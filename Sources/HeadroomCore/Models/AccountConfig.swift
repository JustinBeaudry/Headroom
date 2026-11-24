import Foundation

public enum GeminiLane: String, Codable, CaseIterable, Sendable, Hashable {
    case auto
    case cli
    case gcpQuota = "gcp_quota"
    case apiKey = "api_key"

    public var displayName: String {
        switch self {
        case .auto: return "Auto-Detect"
        case .cli: return "Gemini CLI / Local Logs"
        case .gcpQuota: return "GCP Code Assist Quota"
        case .apiKey: return "Gemini API Key Budget"
        }
    }
}

public struct AccountConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(provider.rawValue):\(label)" }

    public let provider: ProviderID
    public var label: String
    public var enabled: Bool
    public var geminiLane: GeminiLane?
    public var gcpProjectId: String?
    public var apiBudgetUSD: Double?
    public var dailyRequestLimit: Double?
    public var claudeOrgId: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case label
        case enabled
        case geminiLane = "gemini_lane"
        case gcpProjectId = "gcp_project_id"
        case apiBudgetUSD = "api_budget_usd"
        case dailyRequestLimit = "daily_request_limit"
        case claudeOrgId = "claude_org_id"
    }

    public init(
        provider: ProviderID,
        label: String = "personal",
        enabled: Bool = true,
        geminiLane: GeminiLane? = nil,
        gcpProjectId: String? = nil,
        apiBudgetUSD: Double? = nil,
        dailyRequestLimit: Double? = nil,
        claudeOrgId: String? = nil
    ) {
        self.provider = provider
        self.label = label
        self.enabled = enabled
        self.geminiLane = geminiLane
        self.gcpProjectId = gcpProjectId
        self.apiBudgetUSD = apiBudgetUSD
        self.dailyRequestLimit = dailyRequestLimit
        self.claudeOrgId = claudeOrgId
    }
}

public struct PollingConfig: Codable, Sendable, Hashable {
    public var activeIntervalSec: Int
    public var idleIntervalSec: Int
    public var idleThresholdSec: Int
    public var staleAfterSec: Int
    public var maxBackoffSec: Int

    enum CodingKeys: String, CodingKey {
        case activeIntervalSec = "active_interval_sec"
        case idleIntervalSec = "idle_interval_sec"
        case idleThresholdSec = "idle_threshold_sec"
        case staleAfterSec = "stale_after_sec"
        case maxBackoffSec = "max_backoff_sec"
    }

    public init(
        activeIntervalSec: Int = 90,
        idleIntervalSec: Int = 1200,
        idleThresholdSec: Int = 600,
        staleAfterSec: Int = 1800,
        maxBackoffSec: Int = 3600
    ) {
        self.activeIntervalSec = activeIntervalSec
        self.idleIntervalSec = idleIntervalSec
        self.idleThresholdSec = idleThresholdSec
        self.staleAfterSec = staleAfterSec
        self.maxBackoffSec = maxBackoffSec
    }
}

public struct AlertConfig: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var lowHeadroomThresholdPercent: Double
    public var notifyProjectedExhaustion: Bool
    public var notifyWindowReset: Bool
    public var notifyAuthExpired: Bool
    public var cooldownSec: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case lowHeadroomThresholdPercent = "low_headroom_threshold_percent"
        case notifyProjectedExhaustion = "notify_projected_exhaustion"
        case notifyWindowReset = "notify_window_reset"
        case notifyAuthExpired = "notify_auth_expired"
        case cooldownSec = "cooldown_sec"
    }

    public init(
        enabled: Bool = true,
        lowHeadroomThresholdPercent: Double = 20.0,
        notifyProjectedExhaustion: Bool = true,
        notifyWindowReset: Bool = true,
        notifyAuthExpired: Bool = true,
        cooldownSec: Int = 3600
    ) {
        self.enabled = enabled
        self.lowHeadroomThresholdPercent = lowHeadroomThresholdPercent
        self.notifyProjectedExhaustion = notifyProjectedExhaustion
        self.notifyWindowReset = notifyWindowReset
        self.notifyAuthExpired = notifyAuthExpired
        self.cooldownSec = cooldownSec
    }
}

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Sendable, Hashable {
    case mostUrgent = "most_urgent"
    case miniBars = "mini_bars"

    public var displayName: String {
        switch self {
        case .mostUrgent: return "Most Urgent Limit"
        case .miniBars: return "Mini Stacked Bars"
        }
    }
}

public struct HeadroomConfig: Codable, Sendable, Hashable {
    public var accounts: [AccountConfig]
    public var polling: PollingConfig
    public var alerts: AlertConfig
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var deduplicateSharedPools: Bool

    enum CodingKeys: String, CodingKey {
        case accounts
        case polling
        case alerts
        case menuBarDisplayMode = "menu_bar_display_mode"
        case deduplicateSharedPools = "deduplicate_shared_pools"
    }

    public init(
        accounts: [AccountConfig] = HeadroomConfig.defaultAccounts(),
        polling: PollingConfig = PollingConfig(),
        alerts: AlertConfig = AlertConfig(),
        menuBarDisplayMode: MenuBarDisplayMode = .mostUrgent,
        deduplicateSharedPools: Bool = true
    ) {
        self.accounts = accounts
        self.polling = polling
        self.alerts = alerts
        self.menuBarDisplayMode = menuBarDisplayMode
        self.deduplicateSharedPools = deduplicateSharedPools
    }

    public static func defaultAccounts() -> [AccountConfig] {
        [
            AccountConfig(provider: .claude, label: "personal", enabled: true),
            AccountConfig(provider: .codex, label: "personal", enabled: true),
            AccountConfig(provider: .gemini, label: "personal", enabled: true, geminiLane: .auto, dailyRequestLimit: 1000),
            AccountConfig(provider: .grok, label: "personal", enabled: true),
            AccountConfig(provider: .cursor, label: "personal", enabled: true)
        ]
    }
}
