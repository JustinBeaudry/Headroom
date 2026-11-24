import Foundation

public struct GeminiAdapter: ProviderAdapter {
    public let provider: ProviderID = .gemini

    public init() {}

    public func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot {
        let now = context.now()
        let lane = account.geminiLane ?? .auto
        let creds = context.credentials.discover(for: account)
        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: now)
        let localDaily: LocalUsageSummary
        if account.resolvedAllowGlobalCLI {
            localDaily = context.logParser.parseGeminiLogs(since: startOfDay)
        } else {
            localDaily = LocalUsageSummary(provider: .gemini, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0, earliestEvent: nil, latestEvent: nil)
        }
        let localCost = localDaily.estimatedCostUSD > 0 ? localDaily.estimatedCostUSD : nil

        switch lane {
        case .gcpQuota:
            return await fetchLiveCodeAssistQuota(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)

        case .apiKey:
            return buildAPIKeyLane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .cli:
            return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .auto:
            // 1. Try live Google Code Assist / Gemini CLI OAuth quota endpoint first when OAuth is present
            if creds.contains(where: { $0.kind == .oauthToken }) {
                let live = await fetchLiveCodeAssistQuota(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)
                if live.status == .ok {
                    return live
                }
                // Only fall back to local CLI log count when there are actual requests logged today
                if localDaily.requestCount > 0 {
                    return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)
                }
                // Otherwise return the honest live status (e.g. authExpired or subscription notice)
                // instead of fabricating a misleading "100% left (0 / 1000 req)" bar.
                return live
            }
            if localDaily.requestCount > 0 {
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
                message: "No Gemini CLI OAuth (~/.gemini/oauth_creds.json), GCP project, or GEMINI_API_KEY detected."
            )
        }
    }

    private func fetchLiveCodeAssistQuota(
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
                message: "Gemini quota lane requires OAuth token (sign in via `gemini` CLI or gcloud)."
            )
        }

        // Refresh expired Google OAuth access token automatically when local gemini-cli OAuth config is available
        var bearerToken = oauth.value
        if isTokenExpired(oauth, now: now), let refreshToken = oauth.metadata["refresh_token"] {
            if let refreshed = await refreshGeminiOAuthToken(refreshToken: refreshToken, httpClient: httpClient) {
                bearerToken = refreshed
            }
        }

        let headers = [
            "Authorization": "Bearer \(bearerToken)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]

        // 1. If user explicitly set a GCP project ID, try cloudaicompanion.googleapis.com first
        if let project = account.gcpProjectId, !project.isEmpty,
           let gcpURL = URL(string: "https://cloudaicompanion.googleapis.com/v1/projects/\(project)/locations/global:retrieveUserQuota") {
            if let snap = await queryQuotaEndpoint(
                url: gcpURL,
                body: Data("{}".utf8),
                headers: headers,
                accountLabel: account.label,
                source: "gcp_quota:\(oauth.source)",
                localCost: localCost,
                now: now,
                httpClient: httpClient
            ) {
                return snap
            }
        }

        // 2. Discover project via cloudcode-pa.googleapis.com/v1internal:loadCodeAssist (Gemini CLI / Code Assist standard flow)
        var discoveredProject: String? = account.gcpProjectId
        if discoveredProject == nil,
           let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") {
            let loadBody = Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
            if let loadResp = try? await httpClient.send(HTTPRequest(url: loadURL, method: "POST", headers: headers, body: loadBody)) {
                if loadResp.isAuthFailure {
                    return ProviderSnapshot(
                        provider: .gemini,
                        accountLabel: account.label,
                        status: .authExpired,
                        windows: [],
                        fetchedAt: now,
                        source: oauth.source,
                        billingModel: .subscription,
                        message: "Gemini CLI OAuth token expired (HTTP \(loadResp.statusCode)). Run `gemini` once to refresh login."
                    )
                }
                if loadResp.isSuccess, let json = loadResp.jsonObject() as? [String: Any] {
                    if let proj = json["cloudaicompanionProject"] as? String, !proj.isEmpty {
                        discoveredProject = proj
                    }
                }
            }
        }

        guard let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            return ProviderSnapshot(provider: .gemini, accountLabel: account.label, status: .incident, windows: [], fetchedAt: now, message: "Invalid Gemini quota URL.")
        }

        let quotaBody: Data
        if let proj = discoveredProject, !proj.isEmpty {
            quotaBody = (try? JSONSerialization.data(withJSONObject: ["project": proj])) ?? Data("{}".utf8)
        } else {
            quotaBody = Data("{}".utf8)
        }

        if let snap = await queryQuotaEndpoint(
            url: quotaURL,
            body: quotaBody,
            headers: headers,
            accountLabel: account.label,
            source: "code_assist:\(oauth.source)",
            localCost: localCost,
            now: now,
            httpClient: httpClient
        ) {
            return snap
        }

        return ProviderSnapshot(
            provider: .gemini,
            accountLabel: account.label,
            status: .incident,
            windows: [],
            fetchedAt: now,
            source: oauth.source,
            billingModel: .subscription,
            message: "Could not retrieve live Gemini quota."
        )
    }

    private func queryQuotaEndpoint(
        url: URL,
        body: Data,
        headers: [String: String],
        accountLabel: String,
        source: String,
        localCost: Double?,
        now: Date,
        httpClient: any HTTPClient
    ) async -> ProviderSnapshot? {
        do {
            let resp = try await httpClient.send(HTTPRequest(url: url, method: "POST", headers: headers, body: body))
            if resp.statusCode == 401 {
                return ProviderSnapshot(
                    provider: .gemini,
                    accountLabel: accountLabel,
                    status: .authExpired,
                    windows: [],
                    fetchedAt: now,
                    source: source,
                    billingModel: .subscription,
                    message: "Gemini OAuth token expired (HTTP 401). Run `gemini` CLI to re-authenticate."
                )
            }
            if resp.statusCode == 403 {
                let rawText = String(data: resp.body, encoding: .utf8) ?? ""
                let msg = rawText.contains("SUBSCRIPTION_REQUIRED")
                    ? "Google account in ~/.gemini/oauth_creds.json has no active Gemini Code Assist license. Switch lane to CLI Logs or API Key in Settings, or sign into Gemini CLI with a licensed account."
                    : "Gemini quota API denied access (HTTP 403). Verify Gemini Code Assist subscription or switch lane in Settings."
                return ProviderSnapshot(
                    provider: .gemini,
                    accountLabel: accountLabel,
                    status: .stale,
                    windows: [],
                    fetchedAt: now,
                    source: source,
                    billingModel: .subscription,
                    message: msg,
                    estimatedLocalCostUSD: localCost
                )
            }
            guard resp.isSuccess, let json = resp.jsonObject() as? [String: Any] else {
                return nil
            }
            let windows = Self.parseGCPQuotaPayload(json, now: now)
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: accountLabel,
                status: .ok,
                windows: windows,
                fetchedAt: now,
                source: source,
                billingModel: .subscription,
                message: windows.isEmpty ? "Connected to Gemini Code Assist (no active quota buckets returned)." : nil,
                estimatedLocalCostUSD: localCost
            )
        } catch {
            return ProviderSnapshot(
                provider: .gemini,
                accountLabel: accountLabel,
                status: .incident,
                windows: [],
                fetchedAt: now,
                source: source,
                billingModel: .subscription,
                message: "Gemini quota request failed: \(error.localizedDescription)"
            )
        }
    }

    private func isTokenExpired(_ cred: DiscoveredCredential, now: Date) -> Bool {
        guard let expStr = cred.metadata["expiry_ms"], let expMs = Double(expStr) else {
            return false
        }
        return Date(timeIntervalSince1970: expMs / 1000.0) <= now.addingTimeInterval(60)
    }

    private func refreshGeminiOAuthToken(refreshToken: String, httpClient: any HTTPClient) async -> String? {
        guard let (clientId, clientSecret) = Self.discoverLocalGeminiCLIOAuthClient(),
              let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            return nil
        }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        guard let bodyStr = comps.percentEncodedQuery else { return nil }
        let req = HTTPRequest(
            url: tokenURL,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(bodyStr.utf8),
            timeoutInterval: 10
        )
        guard let resp = try? await httpClient.send(req),
              resp.isSuccess,
              let json = resp.jsonObject() as? [String: Any],
              let newToken = json["access_token"] as? String, !newToken.isEmpty else {
            return nil
        }
        return newToken
    }

    /// Reads the public installed-app OAuth client config from a local `@google/gemini-cli` installation at runtime.
    private static func discoverLocalGeminiCLIOAuthClient() -> (String, String)? {
        let candidateBins = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        let fm = FileManager.default
        for bin in candidateBins where fm.fileExists(atPath: bin) {
            let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath()
            let bundleDir = resolved.deletingLastPathComponent()
            guard let files = try? fm.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "js" {
                guard let content = try? String(contentsOf: file, encoding: .utf8),
                      content.contains("OAUTH_CLIENT_ID") else {
                    continue
                }
                if let cid = firstRegexCapture(#"OAUTH_CLIENT_ID\s*=\s*"([^"]+)""#, in: content),
                   let csec = firstRegexCapture(#"OAUTH_CLIENT_SECRET\s*=\s*"([^"]+)""#, in: content) {
                    return (cid, csec)
                }
            }
        }
        return nil
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
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
            // Keep the tightest bucket per model family (e.g. Pro vs Flash) to avoid duplicate rows
            var byFamily: [String: (label: String, usedPct: Double, resetAt: Date?)] = [:]
            for bucket in buckets {
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
                let lower = modelId.lowercased()
                let familyKey: String
                let familyLabel: String
                if lower.contains("pro") {
                    familyKey = "gemini_pro"
                    familyLabel = "Gemini Pro Quota"
                } else if lower.contains("flash") {
                    familyKey = "gemini_flash"
                    familyLabel = "Gemini Flash Quota"
                } else {
                    familyKey = "gcp_\(modelId)"
                    familyLabel = "Code Assist (\(modelId))"
                }
                if let existing = byFamily[familyKey] {
                    if usedPct > existing.usedPct {
                        byFamily[familyKey] = (familyLabel, usedPct, resetAt ?? existing.resetAt)
                    }
                } else {
                    byFamily[familyKey] = (familyLabel, usedPct, resetAt)
                }
            }
            for (key, entry) in byFamily.sorted(by: { $0.key < $1.key }) {
                windows.append(QuotaWindow(
                    id: key,
                    label: entry.label,
                    unit: .percent,
                    used: entry.usedPct,
                    limit: 100.0,
                    resetsAt: entry.resetAt,
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
