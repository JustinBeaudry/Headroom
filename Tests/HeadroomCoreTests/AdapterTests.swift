import XCTest
@testable import HeadroomCore

final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = (HTTPRequest) throws -> HTTPResponse
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try handler(request)
    }
}

struct StubLogParser: LocalLogParsing {
    var claude = LocalUsageSummary(provider: .claude, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0, earliestEvent: nil, latestEvent: nil)
    var codex = LocalUsageSummary(provider: .codex, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0, earliestEvent: nil, latestEvent: nil)
    var gemini = LocalUsageSummary(provider: .gemini, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 0, earliestEvent: nil, latestEvent: nil)

    func parseClaudeLogs(since: Date) -> LocalUsageSummary { claude }
    func parseCodexLogs(since: Date) -> LocalUsageSummary { codex }
    func parseGeminiLogs(since: Date) -> LocalUsageSummary { gemini }
}

final class AdapterTests: XCTestCase {
    let fixedNow = ISO8601DateFormatter().date(from: "2026-11-23T20:00:00Z")!

    private func makeContext(
        secrets: [(ProviderID, String, CredentialKind, String)] = [],
        logParser: any LocalLogParsing = StubLogParser(),
        httpHandler: @escaping MockHTTPClient.Handler
    ) throws -> AdapterContext {
        let store = InMemorySecretStore()
        for (provider, label, kind, val) in secrets {
            try store.setSecret(val, provider: provider, accountLabel: label, kind: kind)
        }
        let emptyHome = URL(fileURLWithPath: "/nonexistent-headroom-test-home")
        let discovery = CredentialDiscovery(secretStore: store, homeDirectory: emptyHome, environment: [:], readExternalKeychain: false)
        return AdapterContext(
            httpClient: MockHTTPClient(handler: httpHandler),
            credentials: discovery,
            logParser: logParser,
            now: { [fixedNow] in fixedNow }
        )
    }

    func testClaudeSessionCookieAdapterParses5hWeeklyAndExtraUsage() async throws {
        let ctx = try makeContext(
            secrets: [(.claude, "personal", .sessionCookie, "sk-ant-sid01-test")]
        ) { req in
            if req.url.path == "/api/organizations" {
                let body = #"[{"uuid":"org-123"}]"#.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            }
            if req.url.path == "/api/organizations/org-123/usage" {
                let body = """
                {
                  "five_hour": { "utilization": 64.0, "resets_at": "2026-11-23T22:00:00Z" },
                  "seven_day": { "utilization": 32.0, "resets_at": "2026-11-28T00:00:00Z" },
                  "extra_usage": { "is_enabled": true, "used_usd": 4.5, "limit_usd": 20.0 }
                }
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            }
            return HTTPResponse(statusCode: 404, body: Data())
        }

        let snap = await ClaudeAdapter().fetchUsage(account: AccountConfig(provider: .claude), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.windows.count, 3)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "session_5h" })?.used, 64.0)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "extra_usage" })?.unit, .dollars)
    }

    func testClaudeExpiredCookieReturnsAuthExpired() async throws {
        let ctx = try makeContext(
            secrets: [(.claude, "personal", .sessionCookie, "expired-cookie")]
        ) { _ in
            HTTPResponse(statusCode: 401, body: Data())
        }
        let snap = await ClaudeAdapter().fetchUsage(account: AccountConfig(provider: .claude), context: ctx)
        XCTAssertEqual(snap.status, .authExpired)
    }

    func testCodexOAuthParsesSubscriptionWindows() async throws {
        let ctx = try makeContext(
            secrets: [(.codex, "personal", .oauthToken, "oauth-tok")]
        ) { _ in
            let body = """
            {
              "rate_limit": {
                "primary_window": { "used_percent": 78, "limit_window_seconds": 18000, "reset_after_seconds": 7200 },
                "secondary_window": { "used_percent": 40, "limit_window_seconds": 604800, "reset_after_seconds": 300000 }
              }
            }
            """.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: body)
        }
        let snap = await CodexAdapter().fetchUsage(account: AccountConfig(provider: .codex), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.billingModel, .subscription)
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.windows[0].used, 78)
    }

    func testCursorDetectsUnifiedXSubscriptionAndIgnoresLegacyExhaustedFields() async throws {
        let ctx = try makeContext(
            secrets: [(.cursor, "personal", .sessionCookie, "workos-token")]
        ) { req in
            if req.url.path.contains("get-sand-usage-status") {
                let body = """
                {
                  "isUnified": true,
                  "billingBrand": "SAND_BILLING_BRAND_GROK",
                  "weeklyPool": {
                    "usedPercent": 42.0,
                    "resetsAt": "2026-11-27T00:00:00Z"
                  },
                  "thirdPartySpend": {
                    "usedUsd": 12.50,
                    "limitUsd": 50.00
                  }
                }
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            }
            // Legacy endpoint reports 100% used on old monthly fields, which MUST NOT be treated as exhausted!
            let legacyBody = """
            {
              "planUsage": { "totalSpend": 2000, "limit": 2000, "totalPercentUsed": 100 }
            }
            """.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: legacyBody)
        }

        let snap = await CursorAdapter().fetchUsage(account: AccountConfig(provider: .cursor), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.billingModel, .xSubscriptionUnified)
        XCTAssertEqual(snap.windows.count, 2)
        let weekly = try XCTUnwrap(snap.windows.first(where: { $0.id == "x_weekly_pool" }))
        XCTAssertEqual(weekly.used, 42.0)
        XCTAssertEqual(weekly.sharedPoolId, CursorAdapter.xSubscriptionPoolID)
        let tp = try XCTUnwrap(snap.windows.first(where: { $0.id == "third_party_spend" }))
        XCTAssertEqual(tp.used, 12.5)
        XCTAssertEqual(tp.limit, 50.0)
    }

    func testCursorGetSandUsageStatusConnectRPCLiveShape() async throws {
        let ctx = try makeContext(
            secrets: [(.cursor, "personal", .oauthToken, "cursor-jwt")]
        ) { req in
            if req.url.path.contains("GetSandUsageStatus") {
                let body = """
                {
                  "currentPeriodStart": "2026-11-20T15:10:15.472Z",
                  "nextResetTimestampUtc": "2026-11-27T15:10:15.472Z",
                  "usagePercent": 62,
                  "grokPlanLabel": "Grok Bot Plan",
                  "cursorPlanName": "Super",
                  "isUnified": true,
                  "billingBrand": "SAND_BILLING_BRAND_GROK",
                  "additionalUsageLimit": {
                    "state": "STATE_NONE",
                    "spentCents": "2342",
                    "resetsAt": "2026-12-01T00:00:00Z"
                  }
                }
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            }
            return HTTPResponse(statusCode: 200, body: #"{"planUsage":{"totalPercentUsed":100}}"#.data(using: .utf8)!)
        }

        let snap = await CursorAdapter().fetchUsage(account: AccountConfig(provider: .cursor), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.billingModel, .xSubscriptionUnified)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "x_weekly_pool" })?.used, 62)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "x_weekly_pool" })?.sharedPoolId, CursorAdapter.xSubscriptionPoolID)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "third_party_spend" })?.used ?? 0, 23.42, accuracy: 0.01)
    }

    func testCursorLegacyMonthlyBillingParsesCorrectly() async throws {
        let ctx = try makeContext(
            secrets: [(.cursor, "personal", .oauthToken, "cursor-jwt")]
        ) { req in
            if req.url.path.contains("get-sand-usage-status") {
                return HTTPResponse(statusCode: 200, body: #"{"isUnified": false}"#.data(using: .utf8)!)
            }
            let body = """
            {
              "billingCycleEnd": "2026-12-01T00:00:00Z",
              "planUsage": { "totalSpend": 850, "limit": 2000 },
              "spendLimitUsage": { "individualUsed": 300, "individualLimit": 5000 }
            }
            """.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: body)
        }
        let snap = await CursorAdapter().fetchUsage(account: AccountConfig(provider: .cursor), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.billingModel, .legacyMonthly)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "monthly_pool" })?.used, 8.5)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "on_demand_spend" })?.limit, 50.0)
    }

    func testGrokDashboardAndXAIAPICredits() async throws {
        let ctx = try makeContext(
            secrets: [
                (.grok, "personal", .sessionCookie, "sso-val"),
                (.grok, "personal", .apiKey, "xai-key")
            ]
        ) { req in
            if req.url.host == "grok.com" {
                let body = """
                {
                  "is_unified_x_subscription": true,
                  "weekly_pool": { "used_percent": 42.0, "resets_at": "2026-11-27T00:00:00Z" }
                }
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            }
            let apiBody = #"{"remaining_usd": 18.0, "total_usd": 25.0}"#.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: apiBody)
        }

        let snap = await GrokAdapter().fetchUsage(account: AccountConfig(provider: .grok), context: ctx)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.billingModel, .hybrid)
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "x_weekly_pool" })?.sharedPoolId, GrokAdapter.xSubscriptionPoolID)
        XCTAssertEqual(snap.windows.first(where: { $0.id == "xai_api_credits" })?.used, 7.0)
    }

    func testGeminiLaneSwitchingCLIVsGCPQuota() async throws {
        var logs = StubLogParser()
        logs.gemini = LocalUsageSummary(
            provider: .gemini,
            requestCount: 150,
            inputTokens: 100_000,
            outputTokens: 25_000,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.375,
            earliestEvent: fixedNow.addingTimeInterval(-3600),
            latestEvent: fixedNow
        )

        let ctx = try makeContext(
            secrets: [(.gemini, "personal", .oauthToken, "goog-oauth")],
            logParser: logs
        ) { _ in
            let body = #"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.72,"resetTime":"2026-11-24T00:00:00Z"}]}"#.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: body)
        }

        let cliAccount = AccountConfig(provider: .gemini, label: "personal", geminiLane: .cli, dailyRequestLimit: 1000)
        let cliSnap = await GeminiAdapter().fetchUsage(account: cliAccount, context: ctx)
        XCTAssertEqual(cliSnap.status, .ok)
        XCTAssertEqual(cliSnap.windows.first?.unit, .requests)
        XCTAssertEqual(cliSnap.windows.first?.used, 150)

        let gcpAccount = AccountConfig(provider: .gemini, label: "personal", geminiLane: .gcpQuota, gcpProjectId: "my-proj")
        let gcpSnap = await GeminiAdapter().fetchUsage(account: gcpAccount, context: ctx)
        XCTAssertEqual(gcpSnap.status, .ok)
        XCTAssertEqual(gcpSnap.windows.first?.used ?? 0, 28.0, accuracy: 0.01)
    }
}
