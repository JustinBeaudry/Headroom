import Foundation

public struct ClaudeAdapter: ProviderAdapter {
    public let provider: ProviderID = .claude

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let creds = context.credentials.discover(for: account)
        let localSummary: LocalUsageSummary
        if account.resolvedAllowGlobalCLI {
            localSummary = context.logParser.parseClaudeLogs(since: now.addingTimeInterval(-5 * 3600))
        } else {
            localSummary = LocalUsageSummary(provider: .claude, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0, earliestEvent: nil, latestEvent: nil)
        }
        let localCost = localSummary.estimatedCostUSD > 0 ? localSummary.estimatedCostUSD : nil

        // 1. Primary: claude.ai browser session cookie (captures both web chat + Claude Code shared window)
        if let cookieCred = creds.first(where: { $0.kind == .sessionCookie }) {
            let result = await fetchViaSessionCookie(
                cookie: cookieCred.value,
                orgIdHint: account.claudeOrgId,
                accountLabel: account.label,
                source: cookieCred.source,
                localCost: localCost,
                now: now,
                httpClient: context.httpClient
            )
            if result.status == .ok || result.status == .authExpired {
                return result
            }
        }

        // 2. Secondary: Claude Code CLI OAuth token -> Anthropic OAuth usage endpoint
        var lastAuthError: String?
        if let oauthCred = creds.first(where: { $0.kind == .oauthToken }) {
            let result = await fetchViaOAuthUsage(
                token: oauthCred.value,
                accountLabel: account.label,
                source: oauthCred.source,
                localCost: localCost,
                now: now,
                httpClient: context.httpClient
            )
            if result.status == .ok {
                return result
            }
            lastAuthError = result.message
            if result.status == .authExpired && localSummary.requestCount == 0 {
                return result
            }
        }

        // 3. Fallback: local Claude Code JSONL session logs (telemetry only, no fabricated hard cap)
        if localSummary.requestCount > 0 {
            let formattedTok = QuotaWindow.formatCompactNumber(Double(localSummary.inputTokens + localSummary.outputTokens))
            let cacheTok = QuotaWindow.formatCompactNumber(Double(localSummary.cacheReadTokens))
            let prefix = lastAuthError.map { "\($0) — " } ?? ""
            return ProviderSnapshot(
                provider: .claude,
                accountLabel: account.label,
                status: .stale,
                windows: [],
                fetchedAt: now,
                source: "local_jsonl_fallback",
                billingModel: .subscription,
                message: "\(prefix)Local CLI activity (5h): \(localSummary.requestCount) req, \(formattedTok) tok + \(cacheTok) cached.",
                estimatedLocalCostUSD: localCost
            )
        }

        if let lastAuthError {
            return ProviderSnapshot(
                provider: .claude,
                accountLabel: account.label,
                status: .incident,
                windows: [],
                fetchedAt: now,
                source: nil,
                billingModel: .subscription,
                message: lastAuthError
            )
        }

        return ProviderSnapshot(
            provider: .claude,
            accountLabel: account.label,
            status: .unconfigured,
            windows: [],
            fetchedAt: now,
            source: nil,
            billingModel: .subscription,
            message: "No Claude session cookie or Claude Code OAuth token found. Run `headroom auth set claude --kind cookie`."
        )
    }

    private func fetchViaSessionCookie(
        cookie: String,
        orgIdHint: String?,
        accountLabel: String,
        source: String,
        localCost: Double?,
        now: Date,
        httpClient: any HTTPClient
    ) async -> ProviderSnapshot {
        let cookieHeader = cookie.contains("sessionKey=") ? cookie : "sessionKey=\(cookie)"
        let baseHeaders = [
            "Cookie": cookieHeader,
            "Accept": "application/json",
            "User-Agent": "Headroom/1.0"
        ]

        do {
            var orgId = orgIdHint
            if orgId == nil || orgId?.isEmpty == true {
                guard let orgsURL = URL(string: "https://claude.ai/api/organizations") else {
                    return errorSnapshot(accountLabel: accountLabel, status: .incident, message: "Invalid Claude orgs URL", now: now)
                }
                let orgResp = try await httpClient.send(HTTPRequest(url: orgsURL, headers: baseHeaders))
                if orgResp.isAuthFailure {
                    return errorSnapshot(
                        accountLabel: accountLabel,
                        status: .authExpired,
                        message: "Claude session cookie expired (HTTP \(orgResp.statusCode)). Re-authenticate via claude.ai.",
                        source: source,
                        now: now
                    )
                }
                guard orgResp.isSuccess,
                      let orgs = orgResp.jsonObject() as? [[String: Any]],
                      let firstUUID = orgs.first?["uuid"] as? String else {
                    return errorSnapshot(
                        accountLabel: accountLabel,
                        status: .incident,
                        message: "Could not resolve Claude organization (HTTP \(orgResp.statusCode)).",
                        source: source,
                        now: now
                    )
                }
                orgId = firstUUID
            }

            guard let resolvedOrg = orgId,
                  let usageURL = URL(string: "https://claude.ai/api/organizations/\(resolvedOrg)/usage") else {
                return errorSnapshot(accountLabel: accountLabel, status: .incident, message: "Invalid Claude usage URL", now: now)
            }

            let resp = try await httpClient.send(HTTPRequest(url: usageURL, headers: baseHeaders))
            if resp.isAuthFailure {
                return errorSnapshot(
                    accountLabel: accountLabel,
                    status: .authExpired,
                    message: "Claude session cookie expired (HTTP \(resp.statusCode)).",
                    source: source,
                    now: now
                )
            }
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return errorSnapshot(
                    accountLabel: accountLabel,
                    status: .incident,
                    message: "Claude usage API returned HTTP \(resp.statusCode).",
                    source: source,
                    now: now
                )
            }

            let windows = Self.parseUsagePayload(json, now: now)
            return ProviderSnapshot(
                provider: .claude,
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
            return errorSnapshot(
                accountLabel: accountLabel,
                status: .incident,
                message: "Claude request failed: \(error.localizedDescription)",
                source: source,
                now: now
            )
        }
    }

    private func fetchViaOAuthUsage(
        token: String,
        accountLabel: String,
        source: String,
        localCost: Double?,
        now: Date,
        httpClient: any HTTPClient
    ) async -> ProviderSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return errorSnapshot(accountLabel: accountLabel, status: .incident, message: "Invalid Anthropic OAuth URL", now: now)
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json"
        ]
        do {
            let resp = try await httpClient.send(HTTPRequest(url: url, headers: headers))
            if resp.isAuthFailure {
                return errorSnapshot(
                    accountLabel: accountLabel,
                    status: .authExpired,
                    message: "Claude OAuth token expired (HTTP \(resp.statusCode)). Run `claude` to refresh.",
                    source: source,
                    now: now
                )
            }
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return errorSnapshot(
                    accountLabel: accountLabel,
                    status: .incident,
                    message: "Anthropic OAuth usage returned HTTP \(resp.statusCode).",
                    source: source,
                    now: now
                )
            }
            let windows = Self.parseUsagePayload(json, now: now)
            return ProviderSnapshot(
                provider: .claude,
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
            return errorSnapshot(
                accountLabel: accountLabel,
                status: .incident,
                message: "Claude OAuth request failed: \(error.localizedDescription)",
                source: source,
                now: now
            )
        }
    }

    /// Parses both claude.ai `/usage` and Anthropic `/api/oauth/usage` JSON structures.
    public static func parseUsagePayload(_ json: [String: Any], now: Date = Date()) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        if let fiveHour = json["five_hour"] as? [String: Any],
           let util = DateParsing.doubleValue(fiveHour["utilization"]) {
            let normalized = util <= 1.0 && util > 0 ? util * 100.0 : util
            windows.append(QuotaWindow(
                id: "session_5h",
                label: "5h Session",
                unit: .percent,
                used: normalized,
                limit: 100.0,
                resetsAt: DateParsing.parseEpochOrISO(fiveHour["resets_at"]),
                windowDurationSec: 18000,
                now: now
            ))
        }

        if let sevenDay = json["seven_day"] as? [String: Any],
           let util = DateParsing.doubleValue(sevenDay["utilization"]) {
            let normalized = util <= 1.0 && util > 0 ? util * 100.0 : util
            windows.append(QuotaWindow(
                id: "weekly_7d",
                label: "Weekly Cap",
                unit: .percent,
                used: normalized,
                limit: 100.0,
                resetsAt: DateParsing.parseEpochOrISO(sevenDay["resets_at"]),
                windowDurationSec: 604800,
                now: now
            ))
        }

        if let opus = json["seven_day_opus"] as? [String: Any],
           let util = DateParsing.doubleValue(opus["utilization"]) {
            let normalized = util <= 1.0 && util > 0 ? util * 100.0 : util
            windows.append(QuotaWindow(
                id: "weekly_opus",
                label: "Weekly Opus",
                unit: .percent,
                used: normalized,
                limit: 100.0,
                resetsAt: DateParsing.parseEpochOrISO(opus["resets_at"]),
                windowDurationSec: 604800,
                now: now
            ))
        }

        if let extra = json["extra_usage"] as? [String: Any],
           DateParsing.boolValue(extra["is_enabled"]) != false {
            let usedRaw = DateParsing.doubleValue(extra["used_credits"] ?? extra["spent_usd"] ?? extra["used_usd"])
            let limitRaw = DateParsing.doubleValue(extra["monthly_limit"] ?? extra["limit_usd"])
            if let usedRaw, let limitRaw, limitRaw > 0 {
                // Anthropic sometimes returns credits in cents when > 1000 with integer fields;
                // support explicit `*_cents` vs `*_usd` cleanly.
                let isCents = extra["used_credits"] != nil && extra["spent_usd"] == nil && extra["used_usd"] == nil
                let usedUSD = isCents ? usedRaw / 100.0 : usedRaw
                let limitUSD = isCents ? limitRaw / 100.0 : limitRaw
                windows.append(QuotaWindow(
                    id: "extra_usage",
                    label: "Extra Usage",
                    unit: .dollars,
                    used: usedUSD,
                    limit: limitUSD,
                    resetsAt: DateParsing.parseEpochOrISO(extra["resets_at"]),
                    windowDurationSec: 2_592_000,
                    now: now
                ))
            }
        }

        return windows
    }

    private func errorSnapshot(
        accountLabel: String,
        status: SnapshotStatus,
        message: String,
        source: String? = nil,
        now: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .claude,
            accountLabel: accountLabel,
            status: status,
            windows: [],
            fetchedAt: now,
            source: source,
            billingModel: .subscription,
            message: message
        )
    }
}
