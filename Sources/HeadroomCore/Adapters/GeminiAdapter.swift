import Foundation

public enum AgyStatusBridge {
    /// Atomically persists an official Antigravity CLI (`agy`) statusLine JSON payload for Headroom to read.
    public static func ingestStatusLineData(
        _ rawData: Data,
        to fileURL: URL = HeadroomPaths.agyStatusFileURL,
        now: Date = Date()
    ) throws {
        guard let payload = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            return
        }
        var wrapped = payload
        wrapped["_headroom_captured_at"] = ISO8601DateFormatter().string(from: now)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
        let tmp = dir.appendingPathComponent(".agy-\(UUID().uuidString).tmp")
        try encoded.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }

    /// Parses an official Antigravity CLI (`agy`) statusLine JSON object into a normalized ProviderSnapshot.
    public static func parseStatusPayload(
        _ json: [String: Any],
        accountLabel: String = "personal",
        now: Date = Date()
    ) -> ProviderSnapshot? {
        let capturedAt = DateParsing.parseISO8601(json["_headroom_captured_at"] as? String) ?? now
        let planTier = json["plan_tier"] as? String
        let costObj = json["cost"] as? [String: Any]
        let costUSD = DateParsing.doubleValue(costObj?["total_usd"])

        var windows: [QuotaWindow] = []
        if let quotaMap = json["quota"] as? [String: Any] {
            for (bucketId, rawVal) in quotaMap.sorted(by: { $0.key < $1.key }) {
                guard let bucket = rawVal as? [String: Any] else { continue }
                if DateParsing.boolValue(bucket["disabled"]) == true { continue }

                let resetAt = DateParsing.parseEpochOrISO(bucket["reset_time"])
                    ?? DateParsing.doubleValue(bucket["reset_in_seconds"]).map { capturedAt.addingTimeInterval($0) }
                let resetInSec = DateParsing.doubleValue(bucket["reset_in_seconds"])
                    ?? resetAt.map { max(0, $0.timeIntervalSince(capturedAt)) }

                let durationSec = inferWindowDuration(bucketId: bucketId, resetInSec: resetInSec)
                let label = formatBucketLabel(bucketId)

                if let remFrac = DateParsing.doubleValue(bucket["remaining_fraction"]) {
                    let usedPct = max(0, min(100, (1.0 - remFrac) * 100.0))
                    windows.append(QuotaWindow(
                        id: "agy_\(bucketId)",
                        label: label,
                        unit: .percent,
                        used: usedPct,
                        limit: 100.0,
                        resetsAt: resetAt,
                        windowDurationSec: durationSec,
                        now: now
                    ))
                } else if let remAmount = DateParsing.doubleValue(bucket["remaining_amount"]) {
                    let total = max(remAmount, 100.0)
                    windows.append(QuotaWindow(
                        id: "agy_\(bucketId)",
                        label: label,
                        unit: .requests,
                        used: max(0, total - remAmount),
                        limit: total,
                        resetsAt: resetAt,
                        windowDurationSec: durationSec,
                        now: now
                    ))
                }
            }
        }

        let isStale = now.timeIntervalSince(capturedAt) > 6 * 3600
        let sourceDesc = planTier.map { "agy statusLine (\($0))" } ?? "agy statusLine"
        let msg: String? = windows.isEmpty
            ? "Connected to Antigravity CLI (`agy`), waiting for first quota payload."
            : (isStale ? "Last Antigravity CLI update was over 6h ago; open `agy` to refresh." : nil)

        return ProviderSnapshot(
            provider: .gemini,
            accountLabel: accountLabel,
            status: windows.isEmpty ? .stale : (isStale ? .stale : .ok),
            windows: windows,
            fetchedAt: capturedAt,
            source: sourceDesc,
            billingModel: .subscription,
            message: msg,
            estimatedLocalCostUSD: costUSD
        )
    }

    /// Configures Antigravity CLI's official `statusLine` command in `~/.gemini/antigravity-cli/settings.json`
    /// with `stack_with_default: true` so the built-in status line stays intact while feeding Headroom live quota JSON.
    public static func installStatusLineHook(
        headroomBinaryPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let settingsDir = homeDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let settingsURL = settingsDir.appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        let ingestCmd = "\"\(headroomBinaryPath)\" ingest agy"
        var statusLineObj = (root["statusLine"] as? [String: Any]) ?? [:]
        if let existingCmd = statusLineObj["command"] as? String,
           !existingCmd.isEmpty,
           !existingCmd.contains("ingest agy") {
            // Preserve user's existing statusline script using POSIX sh-safe stdin fan-out
            statusLineObj["command"] = "_hr=$(mktemp); cat > \"$_hr\"; \(ingestCmd) < \"$_hr\" >/dev/null 2>&1; (\(existingCmd)) < \"$_hr\"; rm -f \"$_hr\""
        } else {
            statusLineObj["command"] = ingestCmd
            if statusLineObj["stack_with_default"] == nil {
                statusLineObj["stack_with_default"] = true
            }
        }
        statusLineObj["type"] = "command"
        statusLineObj["enabled"] = true
        root["statusLine"] = statusLineObj

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        return settingsURL
    }

    public static func isHookInstalled(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let settingsURL = homeDirectory.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sl = root["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else {
            return false
        }
        return cmd.contains("ingest agy") && (DateParsing.boolValue(sl["enabled"]) ?? true)
    }

    private static func inferWindowDuration(bucketId: String, resetInSec: Double?) -> Int {
        let lower = bucketId.lowercased()
        if lower.contains("week") { return 604800 }
        if lower.contains("5h") || lower.contains("session") { return 18000 }
        if lower.contains("day") || lower.contains("daily") { return 86400 }
        if let r = resetInSec {
            if r > 90_000 { return 604800 }
            if r > 21_600 { return 86400 }
            return 18000
        }
        return 604800
    }

    private static func formatBucketLabel(_ bucketId: String) -> String {
        let parts = bucketId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word -> String in
                let lower = word.lowercased()
                switch lower {
                case "gpt": return "GPT"
                case "5h": return "5h"
                case "agy": return "Antigravity"
                default: return lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
        return parts.joined(separator: " ")
    }
}

public struct GeminiAdapter: ProviderAdapter {
    public let provider: ProviderID = .gemini
    private let agyStatusURL: URL

    public init(agyStatusURL: URL = HeadroomPaths.agyStatusFileURL) {
        self.agyStatusURL = agyStatusURL
    }

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
        case .antigravity:
            return loadAntigravitySnapshot(account: account, now: now)

        case .gcpQuota:
            return await fetchLiveCodeAssistQuota(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)

        case .apiKey:
            return buildAPIKeyLane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .cli:
            return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)

        case .auto:
            // 1. Prefer live Antigravity CLI (`agy`) statusLine quota feed when present
            if account.resolvedAllowGlobalCLI, let agySnap = readAgyStatusFile(accountLabel: account.label, now: now) {
                return agySnap
            }
            // 2. Try live Google Code Assist OAuth quota endpoint when OAuth is present
            if creds.contains(where: { $0.kind == .oauthToken }) {
                let live = await fetchLiveCodeAssistQuota(account: account, creds: creds, localCost: localCost, now: now, httpClient: context.httpClient)
                if live.status == .ok {
                    return live
                }
                if localDaily.requestCount > 0 {
                    return buildCLILane(account: account, creds: creds, localDaily: localDaily, now: now)
                }
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
                message: "Connect Antigravity CLI (`agy`) in Settings -> Accounts -> Gemini, or add a GEMINI_API_KEY."
            )
        }
    }

    private func loadAntigravitySnapshot(account: AccountConfig, now: Date) -> ProviderSnapshot {
        if let snap = readAgyStatusFile(accountLabel: account.label, now: now) {
            return snap
        }
        let hookInstalled = AgyStatusBridge.isHookInstalled()
        let msg = hookInstalled
            ? "Antigravity CLI hook is installed. Start or send a turn in `agy` to stream live quota into Headroom."
            : "Click 'Connect Antigravity CLI (agy)' in Settings to stream live quota from `agy`."
        return ProviderSnapshot(
            provider: .gemini,
            accountLabel: account.label,
            status: hookInstalled ? .stale : .unconfigured,
            windows: [],
            fetchedAt: now,
            source: hookInstalled ? "agy statusLine (waiting)" : nil,
            billingModel: .subscription,
            message: msg
        )
    }

    private func readAgyStatusFile(accountLabel: String, now: Date) -> ProviderSnapshot? {
        guard FileManager.default.fileExists(atPath: agyStatusURL.path),
              let data = try? Data(contentsOf: agyStatusURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return AgyStatusBridge.parseStatusPayload(json, accountLabel: accountLabel, now: now)
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
