import Foundation

public struct CodexAdapter: ProviderAdapter {
    public let provider: ProviderID = .codex

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let creds = context.credentials.discover(for: .codex, accountLabel: account.label)
        let localSummary = context.logParser.parseCodexLogs(since: now.addingTimeInterval(-5 * 3600))
        let localCost = localSummary.estimatedCostUSD > 0 ? localSummary.estimatedCostUSD : nil

        // 1. Primary: Codex CLI OAuth token -> ChatGPT/Codex subscription usage endpoint
        if let oauth = creds.first(where: { $0.kind == .oauthToken }) {
            let result = await fetchWhamUsage(
                headers: makeOAuthHeaders(token: oauth.value, accountId: oauth.metadata["account_id"]),
                accountLabel: account.label,
                source: oauth.source,
                localCost: localCost,
                now: now,
                httpClient: context.httpClient
            )
            if result.status == .ok || result.status == .authExpired {
                return result
            }
        }

        // 2. Secondary: OpenAI / ChatGPT web dashboard session cookie
        if let cookie = creds.first(where: { $0.kind == .sessionCookie }) {
            let cookieHeader = cookie.value.contains("__Secure-next-auth.session-token=")
                ? cookie.value
                : "__Secure-next-auth.session-token=\(cookie.value)"
            let result = await fetchWhamUsage(
                headers: ["Cookie": cookieHeader, "Accept": "application/json", "User-Agent": "Headroom/1.0"],
                accountLabel: account.label,
                source: cookie.source,
                localCost: localCost,
                now: now,
                httpClient: context.httpClient
            )
            if result.status == .ok || result.status == .authExpired {
                return result
            }
        }

        // 3. Separate lane: Pay-as-you-go OpenAI API credits (distinct from ChatGPT/Codex subscription windows)
        if let apiKey = creds.first(where: { $0.kind == .apiKey }) {
            let budget = account.apiBudgetUSD ?? 50.0
            let spend = localCost ?? 0.0
            let window = QuotaWindow(
                id: "openai_api_credits",
                label: "OpenAI API Spend (PAYG)",
                unit: .dollars,
                used: spend,
                limit: budget,
                resetsAt: nextMonthStart(from: now),
                windowDurationSec: 2_592_000,
                now: now
            )
            return ProviderSnapshot(
                provider: .codex,
                accountLabel: account.label,
                status: .ok,
                windows: [window],
                fetchedAt: now,
                source: apiKey.source,
                billingModel: .payAsYouGo,
                message: "Tracking pay-as-you-go OpenAI API lane separately from Codex subscription windows.",
                estimatedLocalCostUSD: localCost
            )
        }

        // 4. Local Codex JSONL fallback
        if localSummary.requestCount > 0 {
            let window = QuotaWindow(
                id: "codex_local_5h",
                label: "5h Local Codex CLI",
                unit: .tokens,
                used: Double(localSummary.totalTokens),
                limit: 2_000_000,
                resetsAt: now.addingTimeInterval(18000),
                windowDurationSec: 18000,
                now: now
            )
            return ProviderSnapshot(
                provider: .codex,
                accountLabel: account.label,
                status: .stale,
                windows: [window],
                fetchedAt: now,
                source: "local_jsonl_fallback",
                billingModel: .subscription,
                message: "Using local Codex CLI logs only; authenticate Codex CLI for live subscription windows.",
                estimatedLocalCostUSD: localCost
            )
        }

        return ProviderSnapshot(
            provider: .codex,
            accountLabel: account.label,
            status: .unconfigured,
            windows: [],
            fetchedAt: now,
            source: nil,
            billingModel: .subscription,
            message: "No Codex CLI OAuth (~/.codex/auth.json) or OpenAI session cookie found."
        )
    }

    private func makeOAuthHeaders(token: String, accountId: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "Headroom/1.0"
        ]
        if let accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-Id"] = accountId
        }
        return headers
    }

    private func fetchWhamUsage(
        headers: [String: String],
        accountLabel: String,
        source: String,
        localCost: Double?,
        now: Date,
        httpClient: any HTTPClient
    ) async -> ProviderSnapshot {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return ProviderSnapshot(provider: .codex, accountLabel: accountLabel, status: .incident, windows: [], fetchedAt: now, message: "Invalid Codex usage URL")
        }
        do {
            let resp = try await httpClient.send(HTTPRequest(url: url, headers: headers))
            if resp.isAuthFailure {
                return ProviderSnapshot(
                    provider: .codex,
                    accountLabel: accountLabel,
                    status: .authExpired,
                    windows: [],
                    fetchedAt: now,
                    source: source,
                    billingModel: .subscription,
                    message: "Codex/OpenAI session expired (HTTP \(resp.statusCode)). Re-login via `codex` CLI."
                )
            }
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return ProviderSnapshot(
                    provider: .codex,
                    accountLabel: accountLabel,
                    status: .incident,
                    windows: [],
                    fetchedAt: now,
                    source: source,
                    billingModel: .subscription,
                    message: "Codex usage endpoint returned HTTP \(resp.statusCode)."
                )
            }

            let windows = Self.parseWhamPayload(json, now: now)
            return ProviderSnapshot(
                provider: .codex,
                accountLabel: accountLabel,
                status: .ok,
                windows: windows,
                fetchedAt: now,
                source: source,
                billingModel: .subscription,
                message: nil,
                estimatedLocalCostUSD: localCost
            )
        } catch {
            return ProviderSnapshot(
                provider: .codex,
                accountLabel: accountLabel,
                status: .incident,
                windows: [],
                fetchedAt: now,
                source: source,
                billingModel: .subscription,
                message: "Codex request failed: \(error.localizedDescription)"
            )
        }
    }

    public static func parseWhamPayload(_ json: [String: Any], now: Date = Date()) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any],
               let usedPct = DateParsing.doubleValue(primary["used_percent"]) {
                let dur = Int(DateParsing.doubleValue(primary["limit_window_seconds"]) ?? 18000)
                let reset = DateParsing.parseEpochOrISO(primary["reset_at"])
                    ?? DateParsing.doubleValue(primary["reset_after_seconds"]).map { now.addingTimeInterval($0) }
                let windowId = dur >= 500_000 ? "weekly_7d" : "session_5h"
                let windowLabel = dur >= 500_000 ? "Weekly Cap" : (dur <= 21600 ? "5h Session" : "Primary Window")
                windows.append(QuotaWindow(
                    id: windowId,
                    label: windowLabel,
                    unit: .percent,
                    used: usedPct,
                    limit: 100.0,
                    resetsAt: reset,
                    windowDurationSec: dur,
                    now: now
                ))
            }

            if let secondary = rateLimit["secondary_window"] as? [String: Any],
               let usedPct = DateParsing.doubleValue(secondary["used_percent"]) {
                let dur = Int(DateParsing.doubleValue(secondary["limit_window_seconds"]) ?? 604800)
                let reset = DateParsing.parseEpochOrISO(secondary["reset_at"])
                    ?? DateParsing.doubleValue(secondary["reset_after_seconds"]).map { now.addingTimeInterval($0) }
                windows.append(QuotaWindow(
                    id: "weekly_7d",
                    label: "Weekly Cap",
                    unit: .percent,
                    used: usedPct,
                    limit: 100.0,
                    resetsAt: reset,
                    windowDurationSec: dur,
                    now: now
                ))
            }
        }

        // Optional Codex extra credits (distinct from subscription pool)
        if let credits = json["credits"] as? [String: Any],
           DateParsing.boolValue(credits["has_credits"]) == true,
           let balance = DateParsing.doubleValue(credits["balance"]) {
            let total = DateParsing.doubleValue(credits["limit"] ?? credits["total"]) ?? max(balance, 100.0)
            let used = max(0, total - balance)
            windows.append(QuotaWindow(
                id: "codex_credits",
                label: "Codex Credits",
                unit: .dollars,
                used: used,
                limit: total,
                resetsAt: nil,
                windowDurationSec: nil,
                now: now
            ))
        }

        return windows
    }

    private func nextMonthStart(from date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: date)
        let startOfMonth = cal.date(from: comps) ?? date
        return cal.date(byAdding: .month, value: 1, to: startOfMonth) ?? date.addingTimeInterval(2_592_000)
    }
}
