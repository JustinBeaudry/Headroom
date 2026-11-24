import Foundation

public struct GrokAdapter: ProviderAdapter {
    public let provider: ProviderID = .grok
    public static let xSubscriptionPoolID = "x-subscription-weekly"

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let creds = context.credentials.discover(for: account)

        let cookieCred = creds.first(where: { $0.kind == .sessionCookie })
        let apiKeyCred = creds.first(where: { $0.kind == .apiKey })

        guard cookieCred != nil || apiKeyCred != nil else {
            return ProviderSnapshot(
                provider: .grok,
                accountLabel: account.label,
                status: .unconfigured,
                windows: [],
                fetchedAt: now,
                source: nil,
                billingModel: nil,
                message: "No Grok dashboard cookie or XAI_API_KEY found. Sign in at grok.com/dashboard and store session cookie via `headroom auth set grok --kind cookie`."
            )
        }

        var windows: [QuotaWindow] = []
        var sources: [String] = []
        var billingModel: BillingModel = .xSubscriptionUnified
        var status: SnapshotStatus = .ok
        var message: String?

        // 1. Primary: grok.com/dashboard authenticated session cookies -> shared weekly pool % + reset
        if let cookie = cookieCred {
            let dashResult = await fetchDashboardUsage(cookie: cookie.value, now: now, httpClient: context.httpClient)
            sources.append(cookie.source)
            switch dashResult {
            case .success(let parsedWindows, let isUnifiedX):
                windows.append(contentsOf: parsedWindows)
                billingModel = isUnifiedX ? .xSubscriptionUnified : .subscription
            case .authExpired(let msg):
                status = .authExpired
                message = msg
            case .incident(let msg):
                status = .incident
                message = msg
            }
        }

        // 2. Optional: xAI API prepaid credits (api.x.ai)
        if let apiKey = apiKeyCred {
            let apiResult = await fetchXAIAPIBalance(apiKey: apiKey.value, now: now, httpClient: context.httpClient)
            sources.append(apiKey.source)
            switch apiResult {
            case .success(let window):
                windows.append(window)
                if cookieCred == nil {
                    billingModel = .payAsYouGo
                    status = .ok
                } else {
                    billingModel = .hybrid
                }
            case .failure(let msg):
                if windows.isEmpty {
                    status = .incident
                    message = msg
                }
            }
        }

        return ProviderSnapshot(
            provider: .grok,
            accountLabel: account.label,
            status: status,
            windows: windows,
            fetchedAt: now,
            source: sources.joined(separator: " + "),
            billingModel: billingModel,
            message: message
        )
    }

    private enum DashboardOutcome {
        case success(windows: [QuotaWindow], isUnifiedX: Bool)
        case authExpired(String)
        case incident(String)
    }

    private func fetchDashboardUsage(
        cookie: String,
        now: Date,
        httpClient: any HTTPClient
    ) async -> DashboardOutcome {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieHeader: String
        if trimmed.lowercased().hasPrefix("cookie:") {
            cookieHeader = String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.contains("=") {
            cookieHeader = trimmed
        } else {
            cookieHeader = "sso=\(trimmed)"
        }
        let headers = [
            "Cookie": cookieHeader,
            "Accept": "application/json",
            "Referer": "https://grok.com/dashboard",
            "Origin": "https://grok.com",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        ]

        let endpoints = [
            "https://grok.com/rest/subscriptions/usage",
            "https://grok.com/rest/rate-limits"
        ]

        var lastStatus = 0
        var sawAuthFailure = false

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let resp = try await httpClient.send(HTTPRequest(url: url, headers: headers))
                lastStatus = resp.statusCode
                if resp.isAuthFailure {
                    sawAuthFailure = true
                    continue
                }
                if resp.isSuccess, let json = resp.jsonObject() as? [String: Any] {
                    let (windows, isUnified) = Self.parseDashboardPayload(json, now: now)
                    if !windows.isEmpty {
                        return .success(windows: windows, isUnifiedX: isUnified)
                    }
                }
            } catch {
                return .incident("Grok request failed: \(error.localizedDescription)")
            }
        }

        if sawAuthFailure {
            return .authExpired("Grok rejected the session cookie (HTTP \(lastStatus)). Paste the full Cookie header (including sso and sso-rw) from grok.com/dashboard, or use XAI_API_KEY.")
        }
        return .incident("Grok dashboard endpoint returned HTTP \(lastStatus).")
    }

    private enum APIBalanceOutcome {
        case success(QuotaWindow)
        case failure(String)
    }

    private func fetchXAIAPIBalance(
        apiKey: String,
        now: Date,
        httpClient: any HTTPClient
    ) async -> APIBalanceOutcome {
        guard let url = URL(string: "https://api.x.ai/v1/billing/balance") else {
            return .failure("Invalid xAI API URL.")
        }
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json"
        ]
        do {
            let resp = try await httpClient.send(HTTPRequest(url: url, headers: headers))
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return .failure("xAI API billing returned HTTP \(resp.statusCode).")
            }
            let remaining = DateParsing.doubleValue(json["remaining_usd"] ?? json["balance_usd"] ?? json["available_usd"]) ?? 0
            let total = DateParsing.doubleValue(json["total_usd"] ?? json["prepaid_usd"] ?? json["granted_usd"]) ?? max(remaining, 25.0)
            let used = DateParsing.doubleValue(json["used_usd"] ?? json["spent_usd"]) ?? max(0, total - remaining)
            let window = QuotaWindow(
                id: "xai_api_credits",
                label: "xAI Prepaid Credits",
                unit: .dollars,
                used: used,
                limit: max(total, used),
                resetsAt: nil,
                windowDurationSec: nil,
                now: now
            )
            return .success(window)
        } catch {
            return .failure("xAI API request failed: \(error.localizedDescription)")
        }
    }

    public static func parseDashboardPayload(_ json: [String: Any], now: Date = Date()) -> (windows: [QuotaWindow], isUnifiedX: Bool) {
        var windows: [QuotaWindow] = []
        let isUnified = DateParsing.boolValue(json["is_unified_x_subscription"] ?? json["isUnified"]) ?? true

        let weekly = (json["weekly_pool"] as? [String: Any])
            ?? (json["weeklyPool"] as? [String: Any])
            ?? json

        if let usedPct = DateParsing.doubleValue(weekly["used_percent"] ?? weekly["usedPercent"] ?? weekly["utilization"]) {
            let normalized = (usedPct > 0 && usedPct <= 1.0 && weekly["used_percent"] == nil && weekly["usedPercent"] == nil) ? usedPct * 100.0 : usedPct
            let resetAt = DateParsing.parseEpochOrISO(weekly["resets_at"] ?? weekly["resetsAt"] ?? weekly["reset_timestamp"])
            windows.append(QuotaWindow(
                id: "x_weekly_pool",
                label: isUnified ? "X Weekly Pool (Shared)" : "Grok Weekly Pool",
                unit: .percent,
                used: normalized,
                limit: 100.0,
                resetsAt: resetAt,
                windowDurationSec: 604800,
                sharedPoolId: isUnified ? xSubscriptionPoolID : nil,
                now: now
            ))
        }

        if let credits = json["prepaid_credits"] as? [String: Any] {
            let used = DateParsing.doubleValue(credits["used_usd"]) ?? 0
            let limit = DateParsing.doubleValue(credits["limit_usd"] ?? credits["total_usd"]) ?? 0
            if limit > 0 {
                windows.append(QuotaWindow(
                    id: "grok_prepaid_credits",
                    label: "Prepaid Credits",
                    unit: .dollars,
                    used: used,
                    limit: limit,
                    resetsAt: nil,
                    windowDurationSec: nil,
                    now: now
                ))
            }
        }

        return (windows, isUnified)
    }
}
