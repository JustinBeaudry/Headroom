import XCTest
@testable import HeadroomCore

struct FixedActivityDetector: ActivityDetecting {
    let idleSeconds: TimeInterval
    func secondsSinceLastActivity(now: Date) -> TimeInterval { idleSeconds }
}

final class PoolAndAlertTests: XCTestCase {
    func testPoolDeduplicatorLinksCursorAndGrokWithoutDoubleCounting() {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        let reset = now.addingTimeInterval(3 * 86400)

        let cursor = ProviderSnapshot(
            provider: .cursor,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(id: "x_weekly_pool", label: "X Weekly Pool", unit: .percent, used: 48, limit: 100, resetsAt: reset, windowDurationSec: 604800, sharedPoolId: CursorAdapter.xSubscriptionPoolID, now: now),
                QuotaWindow(id: "third_party_spend", label: "3rd-Party API Cap", unit: .dollars, used: 15, limit: 50, now: now)
            ],
            fetchedAt: now,
            billingModel: .xSubscriptionUnified
        )

        let grok = ProviderSnapshot(
            provider: .grok,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(id: "x_weekly_pool", label: "X Weekly Pool", unit: .percent, used: 48, limit: 100, resetsAt: reset, windowDurationSec: 604800, sharedPoolId: GrokAdapter.xSubscriptionPoolID, now: now),
                QuotaWindow(id: "xai_api_credits", label: "xAI Credits", unit: .dollars, used: 5, limit: 25, now: now)
            ],
            fetchedAt: now,
            billingModel: .hybrid
        )

        let claude = ProviderSnapshot(
            provider: .claude,
            accountLabel: "personal",
            status: .ok,
            windows: [
                QuotaWindow(id: "session_5h", label: "5h Session", unit: .percent, used: 20, limit: 100, now: now)
            ],
            fetchedAt: now
        )

        let all = [cursor, grok, claude]
        let pools = PoolDeduplicator.buildSharedPools(from: all)
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools[0].memberProviders, [.cursor, .grok])
        XCTAssertEqual(pools[0].canonicalWindow.used, 48)
        XCTAssertEqual(pools[0].supplementaryWindows.count, 2)

        let standalone = PoolDeduplicator.standaloneSnapshots(from: all, sharedPools: pools)
        XCTAssertEqual(standalone.map(\.provider), [.claude])
    }

    func testAlertEvaluatorTriggersLowHeadroomBurnResetAndAuthExpired() async {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        let evaluator = AlertEvaluator(config: AlertConfig(), historyURL: nil)

        let prevState = HeadroomState(
            updatedAt: now.addingTimeInterval(-300),
            snapshots: [
                ProviderSnapshot(
                    provider: .claude,
                    accountLabel: "personal",
                    status: .ok,
                    windows: [
                        QuotaWindow(id: "session_5h", label: "5h Session", unit: .percent, used: 75, limit: 100, resetsAt: now.addingTimeInterval(3600), windowDurationSec: 18000, now: now.addingTimeInterval(-300))
                    ],
                    fetchedAt: now.addingTimeInterval(-300)
                ),
                ProviderSnapshot(
                    provider: .grok,
                    accountLabel: "personal",
                    status: .ok,
                    windows: [],
                    fetchedAt: now.addingTimeInterval(-300)
                )
            ]
        )

        let currState = HeadroomState(
            updatedAt: now,
            snapshots: [
                // Claude window just reset from 75% -> 2%
                ProviderSnapshot(
                    provider: .claude,
                    accountLabel: "personal",
                    status: .ok,
                    windows: [
                        QuotaWindow(id: "session_5h", label: "5h Session", unit: .percent, used: 2, limit: 100, resetsAt: now.addingTimeInterval(18000), windowDurationSec: 18000, now: now)
                    ],
                    fetchedAt: now
                ),
                // Codex low headroom (12% left) + burning fast
                ProviderSnapshot(
                    provider: .codex,
                    accountLabel: "personal",
                    status: .ok,
                    windows: [
                        QuotaWindow(id: "session_5h", label: "5h Session", unit: .percent, used: 88, limit: 100, resetsAt: now.addingTimeInterval(3 * 3600), windowDurationSec: 18000, now: now)
                    ],
                    fetchedAt: now
                ),
                // Grok cookie expired
                ProviderSnapshot(
                    provider: .grok,
                    accountLabel: "personal",
                    status: .authExpired,
                    windows: [],
                    fetchedAt: now
                )
            ]
        )

        let alerts = await evaluator.evaluate(previous: prevState, current: currState, now: now)
        let kinds = Set(alerts.map(\.kind))
        XCTAssertTrue(kinds.contains(.windowReset))
        XCTAssertTrue(kinds.contains(.lowHeadroom))
        XCTAssertTrue(kinds.contains(.projectedExhaustion))
        XCTAssertTrue(kinds.contains(.authExpired))

        // Second evaluation within cooldown should not duplicate alerts
        let secondAlerts = await evaluator.evaluate(previous: currState, current: currState, now: now.addingTimeInterval(60))
        XCTAssertTrue(secondAlerts.isEmpty)
    }

    func testAdaptivePollerActiveVsIdleAndPerProviderBackoff() async {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        let config = PollingConfig(activeIntervalSec: 90, idleIntervalSec: 1200, idleThresholdSec: 600)

        let activePoller = AdaptivePoller(config: config, activityDetector: FixedActivityDetector(idleSeconds: 120))
        let activeInterval = await activePoller.recommendedInterval(now: now)
        XCTAssertEqual(activeInterval, 90)

        let idlePoller = AdaptivePoller(config: config, activityDetector: FixedActivityDetector(idleSeconds: 900))
        let idleInterval = await idlePoller.recommendedInterval(now: now)
        XCTAssertEqual(idleInterval, 1200)

        // Recording an error for claude backs off claude without affecting codex
        await activePoller.recordOutcome(accountKey: "claude:personal", status: .authExpired, now: now)
        let canPollClaudeImmediately = await activePoller.shouldPoll(accountKey: "claude:personal", now: now.addingTimeInterval(30))
        let canPollCodexImmediately = await activePoller.shouldPoll(accountKey: "codex:personal", now: now.addingTimeInterval(30))
        XCTAssertFalse(canPollClaudeImmediately)
        XCTAssertTrue(canPollCodexImmediately)
    }

    func testLocalLogParserParsesJSONLAndEstimatesCost() {
        let jsonl = """
        {"timestamp":"2026-11-23T19:30:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100000,"output_tokens":10000,"cache_read_input_tokens":50000}}}
        {"timestamp":"2026-11-23T19:45:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":50000,"output_tokens":5000,"cache_read_input_tokens":0}}}
        """.data(using: .utf8)!

        let parser = LocalLogParser()
        let since = ISO8601DateFormatter().date(from: "2026-11-23T19:00:00Z")!
        let summary = parser.parseJSONLData(jsonl, provider: .claude, since: since)

        XCTAssertEqual(summary.requestCount, 2)
        XCTAssertEqual(summary.inputTokens, 150_000)
        XCTAssertEqual(summary.outputTokens, 15_000)
        XCTAssertEqual(summary.cacheReadTokens, 50_000)
        // Sonnet: 0.15M * $3 = $0.45, 0.015M * $15 = $0.225, 0.05M * $0.30 = $0.015 => $0.69
        XCTAssertEqual(summary.estimatedCostUSD, 0.69, accuracy: 0.001)
    }

    func testEngineIsolatesBrokenProviderAndPersistsCacheAtomically() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stateStore = StateStore(fileURL: tempDir.appendingPathComponent("state.json"))
        let configStore = ConfigStore(fileURL: tempDir.appendingPathComponent("config.json"))
        try await configStore.save(HeadroomConfig(accounts: [
            AccountConfig(provider: .claude, label: "personal"),
            AccountConfig(provider: .codex, label: "personal")
        ]))

        let secrets = InMemorySecretStore()
        try secrets.setSecret("bad-cookie", provider: .claude, accountLabel: "personal", kind: .sessionCookie)
        try secrets.setSecret("good-oauth", provider: .codex, accountLabel: "personal", kind: .oauthToken)

        let discovery = CredentialDiscovery(
            secretStore: secrets,
            homeDirectory: tempDir,
            environment: [:],
            readExternalKeychain: false
        )
        let ctx = AdapterContext(
            httpClient: MockHTTPClient { req in
                if req.url.host == "claude.ai" {
                    return HTTPResponse(statusCode: 401, body: Data())
                }
                let body = #"{"rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":18000,"reset_after_seconds":9000}}}"#.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, body: body)
            },
            credentials: discovery,
            logParser: StubLogParser()
        )

        let engine = HeadroomEngine(
            context: ctx,
            stateStore: stateStore,
            configStore: configStore,
            alertEvaluator: AlertEvaluator(historyURL: nil)
        )

        let result = await engine.poll(force: true)
        XCTAssertEqual(result.state.snapshots.count, 2)
        XCTAssertEqual(result.state.snapshots.first(where: { $0.provider == .claude })?.status, .authExpired)
        XCTAssertEqual(result.state.snapshots.first(where: { $0.provider == .codex })?.status, .ok)

        let reloaded = await stateStore.load()
        XCTAssertEqual(reloaded?.snapshots.count, 2)
    }
}
