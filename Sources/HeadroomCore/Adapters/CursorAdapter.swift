import Foundation

public struct CursorAdapter: ProviderAdapter {
    public let provider: ProviderID = .cursor
    public static let xSubscriptionPoolID = "x-subscription-weekly"

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let creds = context.credentials.discover(for: .cursor, accountLabel: account.label)

        let cookieCred = creds.first(where: { $0.kind == .sessionCookie })
        let tokenCred = creds.first(where: { $0.kind == .oauthToken })

        guard cookieCred != nil || tokenCred != nil else {
            return ProviderSnapshot(
                provider: .cursor,
                accountLabel: account.label,
                status: .unconfigured,
                windows: [],
                fetchedAt: now,
                source: nil,
                billingModel: nil,
                message: "No Cursor local credentials or WorkosCursorSessionToken cookie found."
            )
        }

        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Headroom/1.0"
        ]
        let source: String
        if let cookie = cookieCred {
            headers["Cookie"] = cookie.value.contains("WorkosCursorSessionToken=")
                ? cookie.value
                : "WorkosCursorSessionToken=\(cookie.value)"
            source = cookie.source
        } else if let token = tokenCred {
            headers["Authorization"] = "Bearer \(token.value)"
            source = token.source
        } else {
            source = "unknown"
        }

        do {
            // 1. Query `GetCurrentPeriodUsage` (supports both Bearer JWT from Cursor state.vscdb and session cookies)
            var periodJSON: [String: Any]?
            var periodAuthFailed = false
            var periodStatusCode: Int?
            if let periodURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") {
                var rpcHeaders = headers
                rpcHeaders["Connect-Protocol-Version"] = "1"
                let periodResp = try await context.httpClient.send(HTTPRequest(url: periodURL, method: "POST", headers: rpcHeaders, body: Data("{}".utf8)))
                periodStatusCode = periodResp.statusCode
                if periodResp.isAuthFailure {
                    periodAuthFailed = true
                } else if periodResp.isSuccess {
                    periodJSON = periodResp.jsonObject() as? [String: Any]
                }
            }

            // 2. Also query `get-sand-usage-status` to detect unified X Subscription
            //    (`isUnified` / `SAND_BILLING_BRAND_GROK`). Note: web dashboard endpoint may return
            //    403 for Bearer JWTs while `api2.cursor.sh` succeeds, so only treat auth failure as fatal
            //    when `periodJSON` is also unavailable.
            var sandJSON: [String: Any]?
            var sandAuthFailed = false
            var sandStatusCode: Int?
            if let sandURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status") {
                let sandResp = try await context.httpClient.send(HTTPRequest(url: sandURL, method: "POST", headers: headers, body: Data("{}".utf8)))
                sandStatusCode = sandResp.statusCode
                if sandResp.isAuthFailure {
                    sandAuthFailed = true
                } else if sandResp.isSuccess {
                    sandJSON = sandResp.jsonObject() as? [String: Any]
                }
            }

            if sandJSON == nil && periodJSON == nil {
                if periodAuthFailed || sandAuthFailed {
                    let code = periodStatusCode ?? sandStatusCode ?? 401
                    return ProviderSnapshot(
                        provider: .cursor,
                        accountLabel: account.label,
                        status: .authExpired,
                        windows: [],
                        fetchedAt: now,
                        source: source,
                        billingModel: nil,
                        message: "Cursor session expired (HTTP \(code)). Refresh Cursor login or cookie."
                    )
                }
                return ProviderSnapshot(
                    provider: .cursor,
                    accountLabel: account.label,
                    status: .incident,
                    windows: [],
                    fetchedAt: now,
                    source: source,
                    billingModel: nil,
                    message: "Cursor usage endpoints did not return valid JSON (HTTP \(periodStatusCode ?? sandStatusCode ?? 0))."
                )
            }

            let parsed = Self.parseCursorUsage(sandJSON: sandJSON, periodJSON: periodJSON, now: now)
            return ProviderSnapshot(
                provider: .cursor,
                accountLabel: account.label,
                status: .ok,
                windows: parsed.windows,
                fetchedAt: now,
                source: source,
                billingModel: parsed.billingModel,
                message: parsed.note
            )
        } catch {
            return ProviderSnapshot(
                provider: .cursor,
                accountLabel: account.label,
                status: .incident,
                windows: [],
                fetchedAt: now,
                source: source,
                billingModel: nil,
                message: "Cursor request failed: \(error.localizedDescription)"
            )
        }
    }

    public struct ParsedCursorUsage: Sendable {
        public let billingModel: BillingModel
        public let windows: [QuotaWindow]
        public let note: String?
    }

    /// Distinguishes unified X Subscription (`isUnified` / `SAND_BILLING_BRAND_GROK`)
    /// from legacy monthly Cursor billing so X Subscription accounts never falsely read
    /// legacy monthly fields as 100% exhausted.
    public static func parseCursorUsage(
        sandJSON: [String: Any]?,
        periodJSON: [String: Any]?,
        now: Date = Date()
    ) -> ParsedCursorUsage {
        let isUnified = detectUnifiedXSubscription(sandJSON: sandJSON, periodJSON: periodJSON)

        if isUnified {
            var windows: [QuotaWindow] = []

            // Shared weekly Grok / X Subscription pool
            let weeklyPoolObj = (sandJSON?["weeklyPool"] as? [String: Any])
                ?? (sandJSON?["grokPool"] as? [String: Any])
                ?? (sandJSON?["sharedWeeklyPool"] as? [String: Any])
                ?? (periodJSON?["xSubscriptionUsage"] as? [String: Any])
                ?? sandJSON

            if let pool = weeklyPoolObj {
                let usedPct = DateParsing.doubleValue(
                    pool["usedPercent"] ?? pool["used_percent"] ?? pool["utilizationPercent"] ?? pool["percentUsed"]
                )
                let resetAt = DateParsing.parseEpochOrISO(
                    pool["resetsAt"] ?? pool["resets_at"] ?? pool["resetTimestamp"] ?? pool["cycleEnd"]
                )
                if let usedPct {
                    let normalized = (usedPct > 0 && usedPct <= 1.0 && pool["percentUsed"] == nil) ? usedPct * 100.0 : usedPct
                    windows.append(QuotaWindow(
                        id: "x_weekly_pool",
                        label: "X Weekly Pool (Shared)",
                        unit: .percent,
                        used: normalized,
                        limit: 100.0,
                        resetsAt: resetAt,
                        windowDurationSec: 604800,
                        sharedPoolId: xSubscriptionPoolID,
                        now: now
                    ))
                }
            }

            // Separate 3rd-party model API spend cap (Claude/OpenAI/etc. inside Cursor)
            let thirdPartyObj = (sandJSON?["thirdPartySpend"] as? [String: Any])
                ?? (sandJSON?["thirdPartyUsage"] as? [String: Any])
                ?? (periodJSON?["thirdPartySpend"] as? [String: Any])
                ?? (periodJSON?["apiSpend"] as? [String: Any])

            if let tp = thirdPartyObj {
                let (usedUSD, limitUSD) = extractDollars(from: tp)
                if let usedUSD, let limitUSD, limitUSD > 0 {
                    let resetAt = DateParsing.parseEpochOrISO(tp["resetsAt"] ?? tp["billingCycleEnd"] ?? periodJSON?["billingCycleEnd"])
                    windows.append(QuotaWindow(
                        id: "third_party_spend",
                        label: "3rd-Party API Cap",
                        unit: .dollars,
                        used: usedUSD,
                        limit: limitUSD,
                        resetsAt: resetAt,
                        windowDurationSec: 2_592_000,
                        now: now
                    ))
                }
            }

            return ParsedCursorUsage(
                billingModel: .xSubscriptionUnified,
                windows: windows,
                note: "Unified X Subscription detected (shared weekly Grok pool + separate 3rd-party spend cap)."
            )
        }

        // Legacy monthly pool + on-demand spend
        var windows: [QuotaWindow] = []
        let planUsage = (periodJSON?["planUsage"] as? [String: Any]) ?? periodJSON ?? sandJSON ?? [:]
        let cycleEnd = DateParsing.parseEpochOrISO(periodJSON?["billingCycleEnd"] ?? planUsage["billingCycleEnd"])

        if let totalSpendCents = DateParsing.doubleValue(planUsage["totalSpend"] ?? planUsage["usedCents"]),
           let limitCents = DateParsing.doubleValue(planUsage["limit"] ?? planUsage["limitCents"]),
           limitCents > 0 {
            windows.append(QuotaWindow(
                id: "monthly_pool",
                label: "Monthly Plan Pool",
                unit: .dollars,
                used: totalSpendCents / 100.0,
                limit: limitCents / 100.0,
                resetsAt: cycleEnd,
                windowDurationSec: 2_592_000,
                now: now
            ))
        } else if let usedPct = DateParsing.doubleValue(planUsage["totalPercentUsed"] ?? planUsage["percentUsed"]) {
            windows.append(QuotaWindow(
                id: "monthly_pool",
                label: "Monthly Plan Pool",
                unit: .percent,
                used: usedPct,
                limit: 100.0,
                resetsAt: cycleEnd,
                windowDurationSec: 2_592_000,
                now: now
            ))
        }

        if let spendLimit = periodJSON?["spendLimitUsage"] as? [String: Any] {
            let (usedUSD, limitUSD) = extractDollars(from: spendLimit)
            if let usedUSD, let limitUSD, limitUSD > 0 {
                windows.append(QuotaWindow(
                    id: "on_demand_spend",
                    label: "On-Demand Spend",
                    unit: .dollars,
                    used: usedUSD,
                    limit: limitUSD,
                    resetsAt: cycleEnd,
                    windowDurationSec: 2_592_000,
                    now: now
                ))
            }
        }

        return ParsedCursorUsage(
            billingModel: .legacyMonthly,
            windows: windows,
            note: nil
        )
    }

    private static func detectUnifiedXSubscription(sandJSON: [String: Any]?, periodJSON: [String: Any]?) -> Bool {
        for dict in [sandJSON, periodJSON].compactMap({ $0 }) {
            if DateParsing.boolValue(dict["isUnified"] ?? dict["is_unified"]) == true {
                return true
            }
            for key in ["brand", "billingBrand", "billing_brand", "sandBillingBrand"] {
                if let str = dict[key] as? String, str.uppercased().contains("SAND_BILLING_BRAND_GROK") {
                    return true
                }
            }
            if let nested = dict["billing"] as? [String: Any] {
                if DateParsing.boolValue(nested["isUnified"] ?? nested["is_unified"]) == true {
                    return true
                }
                if let str = nested["brand"] as? String, str.uppercased().contains("SAND_BILLING_BRAND_GROK") {
                    return true
                }
            }
        }
        return false
    }

    private static func extractDollars(from obj: [String: Any]) -> (Double?, Double?) {
        if let used = DateParsing.doubleValue(obj["usedUsd"] ?? obj["used_usd"] ?? obj["spentUsd"]),
           let limit = DateParsing.doubleValue(obj["limitUsd"] ?? obj["limit_usd"] ?? obj["capUsd"]) {
            return (used, limit)
        }
        if let usedCents = DateParsing.doubleValue(obj["individualUsed"] ?? obj["usedCents"] ?? obj["used"]),
           let limitCents = DateParsing.doubleValue(obj["individualLimit"] ?? obj["limitCents"] ?? obj["limit"]) {
            return (usedCents / 100.0, limitCents / 100.0)
        }
        return (nil, nil)
    }
}
