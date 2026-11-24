import Foundation

public struct GeminiAdapter: ProviderAdapter {
    public let provider: ProviderID = .gemini

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let lane = account.geminiLane ?? .auto
        let creds = context.credentials.discover(for: .gemini, accountLabel: account.label)
        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: now)
        let localDaily = context.logParser.parseGeminiLogs(since: startOfDay)
        let localCost = localDaily.estimatedCostUSD > 0 ? localDaily.estimatedCostUSD : nil

        switch lane {
        case .gcpQuota:
            return await fetchGCPQuotaLane(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)

        case .apiKey:
            return buildAPIKeyLane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .cli:
            return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .auto:
            // Prefer GCP Code Assist Quota if project + OAuth token exist, then CLI logs/OAuth, then API Key lane.
            if let project = account.gcpProjectId, !project.isEmpty,
               creds.contains(where: { $0.kind == .oauthToken }) {
                let gcp = await fetchGCPQuotaLane(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)
                if gcp.status == .ok { return gcp }
            }
            if localDaily.requestCount > 0 || creds.contains(where: { $0.kind == .oauthToken }) {
                return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)
            }
            if creds.contains(where: { $0.kind == .apiKey }) {
                return buildAPIKeyLane(account: account, creds: creds, localDaily: localDaily, now: now)
            }
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: account.label,
                status: .unconfigured,
                windows: [],
                fetchedAt: now,
                source: nil,
                billingModel: nil,
                message: "No Gemini CLI OAuth (~/.gemini/oauth_creds.json), GCP project, or GEMINI_API_KEY detected. Configure lane via `headroom config set-gemini-lane`."
            )
        }
    }

    private func fetchGCPQuotaLane(
        account: AccountConfig,
        creds: [DiscoveredCredential],
        localCost: Double?,
        now: Date,
        httpClient: any HTTPClient
    ) async -> ProviderSnapshot {
        guard let oauth = creds.first(where: { $0.kind == .oauthToken }) else {
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: account.label,
                status: .authExpired,
                windows: [],
                fetchedAt: now,
                source: "lane:gcp_quota",
                billingModel: .subscription,
                message: "Gemini GCP quota lane requires OAuth token (Gemini CLI or gcloud ADC)."
            )
        }

        let project = account.gcpProjectId ?? "default"
        guard let url = URL(string: "https://cloudaicompanion.googleapis.com/v1/projects/\(project)/locations/global:retrieveUserQuota") else {
            return ProviderSnapshot(provider: .gemini, accountLabel: account.label, status: .incident, windows: [], fetchedAt: now, message: "Invalid GCP quota URL")
        }

        let headers = [
            "Authorization": "Bearer \(oauth.value)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]

        do {
            let resp = try await httpClient.send(HTTPRequest(url: url, method: "POST", headers: headers, body: Data("{}".utf8)))
            if resp.isAuthFailure {
                return ProviderSnapshot(
                    provider: .gemini,
                    accountLabel: account.label,
                    status: .authExpired,
                    windows: [],
                    fetchedAt: now,
                    source: oauth.source,
                    billingModel: .subscription,
                    message: "Google Cloud OAuth expired (HTTP \(resp.statusCode)). Re-authenticate Gemini CLI or gcloud."
                )
            }
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return ProviderSnapshot(
                    provider: .gemini,
                    accountLabel: account.label,
                    status: .incident,
                    windows: [],
                    fetchedAt: now,
                    source: oauth.source,
                    billingModel: .subscription,
                    message: "cloudaicompanion quota API returned HTTP \(resp.statusCode)."
                )
            }

            let windows = Self.parseGCPQuotaPayload(json, now: now)
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: account.label,
                status: .ok,
                windows: windows,
                fetchedAt: now,
                source: "gcp_quota:\(oauth.source)",
                billingModel: .subscription,
                message: nil,
                estimatedLocalCostUSD: localCost
            )
        } catch {
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: account.label,
                status: .incident,
                windows: [],
                fetchedAt: now,
                source: oauth.source,
                billingModel: .subscription,
                message: "GCP quota request failed: \(error.localizedDescription)"
            )
        }
    }

    private func buildCLILane(
        account: AccountConfig,
        creds: [DiscoveredCredential],
        localDaily: LocalUsageSummary,
        now: Date
    ) -> ProviderSnapshot {
        let dailyLimit = account.dailyRequestLimit ?? 1000.0
        let nextDay = nextMidnightUTC(from: now)
        let reqWindow = QuotaWindow(
            id: "daily_requests",
            label: "Daily Requests (CLI)",
            unit: .requests,
            used: Double(localDaily.requestCount),
            limit: dailyLimit,
            resetsAt: nextDay,
            windowDurationSec: 86400,
            now: now
        )
        let source = creds.first(where: { $0.kind == .oauthToken })?.source ?? "local_gemini_cli_logs"
        return ProviderSnapshot(
            provider: .gemini,
            accountLabel: account.label,
            status: .ok,
            windows: [reqWindow],
            fetchedAt: now,
            source: "lane:cli (\(source))",
            billingModel: .subscription,
            message: nil,
            estimatedLocalCostUSD: localDaily.estimatedCostUSD > 0 ? localDaily.estimatedCostUSD : nil
        )
    }

    private func buildAPIKeyLane(
        account: AccountConfig,
        creds: [DiscoveredCredential],
        localDaily: LocalUsageSummary,
        now: Date
    ) -> ProviderSnapshot {
        guard let apiKey = creds.first(where: { $0.kind == .apiKey }) else {
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: account.label,
                status: .unconfigured,
                windows: [],
                fetchedAt: now,
                source: "lane:api_key",
                billingModel: .payAsYouGo,
                message: "Gemini API key lane selected but GEMINI_API_KEY not found."
            )
        }
        let budget = account.apiBudgetUSD ?? 25.0
        let window = QuotaWindow(
            id: "gemini_api_budget",
            label: "API Daily Budget",
            unit: .dollars,
            used: localDaily.estimatedCostUSD,
            limit: budget,
            resetsAt: nextMidnightUTC(from: now),
            windowDurationSec: 86400,
            now: now
        )
        return ProviderSnapshot(
            provider: .gemini,
            accountLabel: account.label,
            status: .ok,
            windows: [window],
            fetchedAt: now,
            source: "lane:api_key (\(apiKey.source))",
            billingModel: .payAsYouGo,
            message: nil,
            estimatedLocalCostUSD: localDaily.estimatedCostUSD > 0 ? localDaily.estimatedCostUSD : nil
        )
    }

    public static func parseGCPQuotaPayload(_ json: [String: Any], now: Date = Date()) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        if let buckets = json["buckets"] as? [[String: Any]] {
            for (idx, bucket) in buckets.enumerated() {
                let modelId = (bucket["modelId"] as? String) ?? "gemini"
                let remainingFraction = DateParsing.doubleValue(bucket["remainingFraction"])
                let usedPct: Double
                if let rem = remainingFraction {
                    usedPct = max(0, min(100, (1.0 - rem) * 100.0))
                } else if let used = DateParsing.doubleValue(bucket["usedPercent"]) {
                    usedPct = used
                } else {
                    continue
                }
                let resetAt = DateParsing.parseEpochOrISO(bucket["resetTime"])
                windows.append(QuotaWindow(
                    id: "gcp_\(modelId)_\(idx)",
                    label: "Code Assist (\(modelId))",
                    unit: .percent,
                    used: usedPct,
                    limit: 100.0,
                    resetsAt: resetAt,
                    windowDurationSec: 86400,
                    now: now
                ))
            }
        }
        return windows
    }

    private func nextMidnightUTC(from date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86400)
    }
}
