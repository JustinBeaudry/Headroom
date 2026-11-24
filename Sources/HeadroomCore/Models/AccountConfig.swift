import Foundation

public enum GeminiLane: String, Codable, CaseIterable, Sendable, Hashable {
    case auto
    case antigravity
    case cli
    case gcpQuota = "gcp_quota"
    case apiKey = "api_key"

    public var displayName: String {
        switch self {
        case .auto: return "Auto-Detect"
        case .antigravity: return "Antigravity CLI (agy)"
        case .cli: return "Legacy Gemini CLI Logs"
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
    /// When false, this account is strictly isolated to its own Keychain credentials and optional `cliConfigDir`
    /// so secondary accounts (e.g. `work`) never leak credentials or local logs from `personal`.
    public var useLocalCLIDiscovery: Bool?
    /// Optional custom CLI config directory (e.g. `~/.claude-work` or `~/.codex-work`) for multi-profile CLI setups.
    public var cliConfigDir: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case label
        case enabled
        case geminiLane = "gemini_lane"
        case gcpProjectId = "gcp_project_id"
        case apiBudgetUSD = "api_budget_usd"
        case dailyRequestLimit = "daily_request_limit"
        case claudeOrgId = "claude_org_id"
        case useLocalCLIDiscovery = "use_local_cli_discovery"
        case cliConfigDir = "cli_config_dir"
    }

    public init(
        provider: ProviderID,
        label: String = "personal",
        enabled: Bool = true,
        geminiLane: GeminiLane? = nil,
        gcpProjectId: String? = nil,
        apiBudgetUSD: Double? = nil,
        dailyRequestLimit: Double? = nil,
        claudeOrgId: String? = nil,
        useLocalCLIDiscovery: Bool? = nil,
        cliConfigDir: String? = nil
    ) {
        self.provider = provider
        self.label = label
        self.enabled = enabled
        self.geminiLane = geminiLane
        self.gcpProjectId = gcpProjectId
        self.apiBudgetUSD = apiBudgetUSD
        self.dailyRequestLimit = dailyRequestLimit
        self.claudeOrgId = claudeOrgId
        self.useLocalCLIDiscovery = useLocalCLIDiscovery
        self.cliConfigDir = cliConfigDir
    }

    public var resolvedAllowGlobalCLI: Bool {
        useLocalCLIDiscovery ?? (label == "personal" || label == "default")
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
    case stackedMetrics = "stacked_metrics"
    case inlineMetrics = "inline_metrics"
    case miniBars = "mini_bars"
    case mostUrgent = "most_urgent"

    public var displayName: String {
        switch self {
        case .stackedMetrics: return "Stacked (iStat Style)"
        case .inlineMetrics: return "Inline Multi-Provider"
        case .miniBars: return "Mini Meter Bars"
        case .mostUrgent: return "Most Urgent Only"
        }
    }

    public var shortDescription: String {
        switch self {
        case .stackedMetrics: return "Two-line label + percentage columns for each pinned provider"
        case .inlineMetrics: return "Single-line percentages side by side (e.g. CDX 99% · CUR 53%)"
        case .miniBars: return "Compact vertical headroom bars with ceiling cap ticks"
        case .mostUrgent: return "Single compact badge for the tightest live quota"
        }
    }
}

public enum MenuBarMetricMode: String, Codable, CaseIterable, Sendable, Hashable {
    case remaining
    case used

    public var displayName: String {
        switch self {
        case .remaining: return "Remaining % (Headroom)"
        case .used: return "Used % (Spent)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .remaining: return "Remaining"
        case .used: return "Used"
        }
    }

    public func percentage(for window: QuotaWindow) -> Double {
        switch self {
        case .remaining: return window.headroomPercent
        case .used: return min(100.0, max(0.0, window.usedPercent))
        }
    }
}

public struct HeadroomConfig: Codable, Sendable, Hashable {
    public var accounts: [AccountConfig]
    public var polling: PollingConfig
    public var alerts: AlertConfig
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var menuBarMetricMode: MenuBarMetricMode
    public var menuBarColorize: Bool
    /// Account IDs (e.g. "claude:work", "codex:personal") or shared pool keys ("x-subscription-weekly:personal")
    /// to display in the menu bar. Empty array = automatically display all live accounts (up to 4).
    public var menuBarPinnedAccounts: [String]
    public var deduplicateSharedPools: Bool

    enum CodingKeys: String, CodingKey {
        case accounts
        case polling
        case alerts
        case menuBarDisplayMode = "menu_bar_display_mode"
        case menuBarMetricMode = "menu_bar_metric_mode"
        case menuBarColorize = "menu_bar_colorize"
        case menuBarPinnedAccounts = "menu_bar_pinned_accounts"
        case deduplicateSharedPools = "deduplicate_shared_pools"
    }

    public init(
        accounts: [AccountConfig] = HeadroomConfig.defaultAccounts(),
        polling: PollingConfig = PollingConfig(),
        alerts: AlertConfig = AlertConfig(),
        menuBarDisplayMode: MenuBarDisplayMode = .stackedMetrics,
        menuBarMetricMode: MenuBarMetricMode = .remaining,
        menuBarColorize: Bool = true,
        menuBarPinnedAccounts: [String] = [],
        deduplicateSharedPools: Bool = true
    ) {
        self.accounts = accounts
        self.polling = polling
        self.alerts = alerts
        self.menuBarDisplayMode = menuBarDisplayMode
        self.menuBarMetricMode = menuBarMetricMode
        self.menuBarColorize = menuBarColorize
        self.menuBarPinnedAccounts = menuBarPinnedAccounts
        self.deduplicateSharedPools = deduplicateSharedPools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accounts = try c.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? HeadroomConfig.defaultAccounts()
        self.polling = try c.decodeIfPresent(PollingConfig.self, forKey: .polling) ?? PollingConfig()
        self.alerts = try c.decodeIfPresent(AlertConfig.self, forKey: .alerts) ?? AlertConfig()
        self.menuBarDisplayMode = try c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .stackedMetrics
        self.menuBarMetricMode = try c.decodeIfPresent(MenuBarMetricMode.self, forKey: .menuBarMetricMode) ?? .remaining
        self.menuBarColorize = try c.decodeIfPresent(Bool.self, forKey: .menuBarColorize) ?? true
        self.menuBarPinnedAccounts = try c.decodeIfPresent([String].self, forKey: .menuBarPinnedAccounts) ?? []
        self.deduplicateSharedPools = try c.decodeIfPresent(Bool.self, forKey: .deduplicateSharedPools) ?? true
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
