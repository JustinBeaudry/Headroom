import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case claude
    case codex
    case gemini
    case grok
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        }
    }

    public var shortCode: String {
        switch self {
        case .claude: return "CLD"
        case .codex: return "CDX"
        case .gemini: return "GEM"
        case .grok: return "GRK"
        case .cursor: return "CUR"
        }
    }

    public var reauthURL: URL? {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .gemini: return URL(string: "https://aistudio.google.com/")
        case .grok: return URL(string: "https://grok.com/dashboard")
        case .cursor: return URL(string: "https://cursor.com/dashboard")
        }
    }
}

public enum SnapshotStatus: String, Codable, Sendable, Hashable {
    case ok
    case stale
    case authExpired = "auth_expired"
    case incident
    case unconfigured
}

public enum QuotaUnit: String, Codable, Sendable, Hashable {
    case percent
    case dollars
    case requests
    case tokens
}

public enum PaceStatus: String, Codable, Sendable, Hashable {
    case reserve
    case onTrack = "on_track"
    case burningFast = "burning_fast"

    public var displayLabel: String {
        switch self {
        case .reserve: return "In Reserve"
        case .onTrack: return "On Track"
        case .burningFast: return "Burning Fast"
        }
    }
}

public enum BillingModel: String, Codable, Sendable, Hashable {
    case subscription
    case xSubscriptionUnified = "x_subscription_unified"
    case legacyMonthly = "legacy_monthly"
    case payAsYouGo = "pay_as_you_go"
    case hybrid
}

public struct PaceAnalysis: Codable, Sendable, Hashable {
    public let usedPercent: Double
    public let headroomPercent: Double
    public let elapsedPercent: Double
    public let paceDeltaPercent: Double
    public let burnRateMultiplier: Double?
    public let projectedPercentAtReset: Double?
    public let projectedExhaustionAt: Date?
    public let willExhaustBeforeReset: Bool
    public let paceStatus: PaceStatus

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case headroomPercent = "headroom_percent"
        case elapsedPercent = "elapsed_percent"
        case paceDeltaPercent = "pace_delta_percent"
        case burnRateMultiplier = "burn_rate_multiplier"
        case projectedPercentAtReset = "projected_percent_at_reset"
        case projectedExhaustionAt = "projected_exhaustion_at"
        case willExhaustBeforeReset = "will_exhaust_before_reset"
        case paceStatus = "pace_status"
    }

    public init(
        usedPercent: Double,
        headroomPercent: Double,
        elapsedPercent: Double,
        paceDeltaPercent: Double,
        burnRateMultiplier: Double?,
        projectedPercentAtReset: Double?,
        projectedExhaustionAt: Date?,
        willExhaustBeforeReset: Bool,
        paceStatus: PaceStatus
    ) {
        self.usedPercent = usedPercent
        self.headroomPercent = headroomPercent
        self.elapsedPercent = elapsedPercent
        self.paceDeltaPercent = paceDeltaPercent
        self.burnRateMultiplier = burnRateMultiplier
        self.projectedPercentAtReset = projectedPercentAtReset
        self.projectedExhaustionAt = projectedExhaustionAt
        self.willExhaustBeforeReset = willExhaustBeforeReset
        self.paceStatus = paceStatus
    }
}

public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let unit: QuotaUnit
    public let used: Double
    public let limit: Double
    public let resetsAt: Date?
    public let windowDurationSec: Int?
    public let paceStatus: PaceStatus
    public let sharedPoolId: String?
    public let paceDetail: PaceAnalysis?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case unit
        case used
        case limit
        case resetsAt = "resets_at"
        case windowDurationSec = "window_duration_sec"
        case paceStatus = "pace_status"
        case sharedPoolId = "shared_pool_id"
        case paceDetail = "pace_detail"
    }

    public init(
        id: String,
        label: String,
        unit: QuotaUnit,
        used: Double,
        limit: Double,
        resetsAt: Date? = nil,
        windowDurationSec: Int? = nil,
        paceStatus: PaceStatus? = nil,
        sharedPoolId: String? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.unit = unit
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
        self.windowDurationSec = windowDurationSec
        self.sharedPoolId = sharedPoolId
        let computed = PaceCalculator.evaluate(
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            windowDurationSec: windowDurationSec,
            now: now
        )
        self.paceDetail = computed
        self.paceStatus = paceStatus ?? computed.paceStatus
    }

    public var usedPercent: Double {
        guard limit > 0 else { return 0 }
        return max(0, (used / limit) * 100.0)
    }

    public var headroomPercent: Double {
        max(0, 100.0 - usedPercent)
    }

    public var formattedUsage: String {
        switch unit {
        case .percent:
            return String(format: "%.0f%%", usedPercent)
        case .dollars:
            return String(format: "$%.2f / $%.2f", used, limit)
        case .requests:
            return "\(Int(used.rounded())) / \(Int(limit.rounded())) req"
        case .tokens:
            return "\(Self.formatCompactNumber(used)) / \(Self.formatCompactNumber(limit)) tok"
        }
    }

    public static func formatCompactNumber(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }
}

public struct ProviderSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(provider.rawValue):\(accountLabel)" }

    public let provider: ProviderID
    public let accountLabel: String
    public let status: SnapshotStatus
    public let windows: [QuotaWindow]
    public let fetchedAt: Date
    public let source: String?
    public let billingModel: BillingModel?
    public let message: String?
    public let estimatedLocalCostUSD: Double?

    enum CodingKeys: String, CodingKey {
        case provider
        case accountLabel = "account_label"
        case status
        case windows
        case fetchedAt = "fetched_at"
        case source
        case billingModel = "billing_model"
        case message
        case estimatedLocalCostUSD = "estimated_local_cost_usd"
    }

    public init(
        provider: ProviderID,
        accountLabel: String = "default",
        status: SnapshotStatus,
        windows: [QuotaWindow],
        fetchedAt: Date = Date(),
        source: String? = nil,
        billingModel: BillingModel? = nil,
        message: String? = nil,
        estimatedLocalCostUSD: Double? = nil
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.status = status
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
        self.billingModel = billingModel
        self.message = message
        self.estimatedLocalCostUSD = estimatedLocalCostUSD
    }

    public var primaryWindow: QuotaWindow? {
        windows.max(by: { PaceCalculator.windowUrgency($0) < PaceCalculator.windowUrgency($1) })
    }

    public var urgencyScore: Double {
        PaceCalculator.snapshotUrgency(self)
    }
}

public struct SharedPoolGroup: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let accountLabel: String
    public let memberProviders: [ProviderID]
    public let canonicalWindow: QuotaWindow
    public let supplementaryWindows: [SupplementaryPoolWindow]

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case accountLabel = "account_label"
        case memberProviders = "member_providers"
        case canonicalWindow = "canonical_window"
        case supplementaryWindows = "supplementary_windows"
    }

    public init(
        id: String,
        label: String,
        accountLabel: String,
        memberProviders: [ProviderID],
        canonicalWindow: QuotaWindow,
        supplementaryWindows: [SupplementaryPoolWindow]
    ) {
        self.id = id
        self.label = label
        self.accountLabel = accountLabel
        self.memberProviders = memberProviders
        self.canonicalWindow = canonicalWindow
        self.supplementaryWindows = supplementaryWindows
    }
}

public struct SupplementaryPoolWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(provider.rawValue):\(window.id)" }
    public let provider: ProviderID
    public let window: QuotaWindow

    public init(provider: ProviderID, window: QuotaWindow) {
        self.provider = provider
        self.window = window
    }
}

public struct HeadroomState: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let snapshots: [ProviderSnapshot]
    public let sharedPools: [SharedPoolGroup]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case snapshots
        case sharedPools = "shared_pools"
    }

    public init(
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        snapshots: [ProviderSnapshot],
        sharedPools: [SharedPoolGroup] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.snapshots = snapshots
        self.sharedPools = sharedPools
    }
}

public enum HeadroomJSON {
    public static func makeEncoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
