import XCTest
@testable import HeadroomCore

final class PacingTests: XCTestCase {
    func testBurningFastProjectsExhaustionBeforeReset() {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        // 5-hour window (18000s), 4 hours left => 1 hour elapsed (20% elapsed), 64% used => burning fast!
        let resetsAt = now.addingTimeInterval(4 * 3600)
        let pace = PaceCalculator.evaluate(
            used: 64.0,
            limit: 100.0,
            resetsAt: resetsAt,
            windowDurationSec: 18000,
            now: now
        )

        XCTAssertEqual(pace.paceStatus, .burningFast)
        XCTAssertEqual(pace.usedPercent, 64.0, accuracy: 0.01)
        XCTAssertEqual(pace.headroomPercent, 36.0, accuracy: 0.01)
        XCTAssertEqual(pace.elapsedPercent, 20.0, accuracy: 0.01)
        XCTAssertEqual(pace.paceDeltaPercent, 44.0, accuracy: 0.01)
        XCTAssertTrue(pace.willExhaustBeforeReset)
        XCTAssertNotNil(pace.projectedExhaustionAt)
        if let exhaust = pace.projectedExhaustionAt {
            XCTAssertLessThan(exhaust, resetsAt)
        }
    }

    func testInReserveWhenUsageTrailsElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        // 7-day window (604800s), 2 days left => 5 days elapsed (~71.4% elapsed), 30% used => in reserve
        let resetsAt = now.addingTimeInterval(2 * 86400)
        let pace = PaceCalculator.evaluate(
            used: 30.0,
            limit: 100.0,
            resetsAt: resetsAt,
            windowDurationSec: 604800,
            now: now
        )

        XCTAssertEqual(pace.paceStatus, .reserve)
        XCTAssertFalse(pace.willExhaustBeforeReset)
        XCTAssertLessThan(pace.paceDeltaPercent, -30.0)
    }

    func testOnTrackWhenUsageMatchesElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_795_460_000)
        // 50% elapsed, 51% used => on track
        let resetsAt = now.addingTimeInterval(9000)
        let pace = PaceCalculator.evaluate(
            used: 51.0,
            limit: 100.0,
            resetsAt: resetsAt,
            windowDurationSec: 18000,
            now: now
        )

        XCTAssertEqual(pace.paceStatus, .onTrack)
    }

    func testNormalizedSnapshotJSONSchemaMatchesSpec() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-23T19:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-11-23T22:00:00Z")!
        let window = QuotaWindow(
            id: "session_5h",
            label: "5h Session",
            unit: .percent,
            used: 64.0,
            limit: 100.0,
            resetsAt: resetsAt,
            windowDurationSec: 18000,
            now: now
        )
        let snapshot = ProviderSnapshot(
            provider: .claude,
            accountLabel: "personal",
            status: .ok,
            windows: [window],
            fetchedAt: now
        )

        let data = try HeadroomJSON.makeEncoder(prettyPrinted: false).encode(snapshot)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["provider"] as? String, "claude")
        XCTAssertEqual(dict["account_label"] as? String, "personal")
        XCTAssertEqual(dict["status"] as? String, "ok")

        let windows = try XCTUnwrap(dict["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        let w = windows[0]
        XCTAssertEqual(w["id"] as? String, "session_5h")
        XCTAssertEqual(w["label"] as? String, "5h Session")
        XCTAssertEqual(w["unit"] as? String, "percent")
        XCTAssertEqual(w["used"] as? Double, 64.0)
        XCTAssertEqual(w["limit"] as? Double, 100.0)
        XCTAssertEqual(w["resets_at"] as? String, "2026-11-23T22:00:00Z")
        XCTAssertEqual(w["window_duration_sec"] as? Int, 18000)
        XCTAssertEqual(w["pace_status"] as? String, "burning_fast")
    }

    func testLegacyConfigDecodesWithNewMenuBarDefaults() throws {
        let legacyJSON = """
        {
          "accounts": [{"provider": "claude", "label": "personal", "enabled": true}],
          "polling": {"active_interval_sec": 90, "idle_interval_sec": 1200, "idle_threshold_sec": 600, "stale_after_sec": 1800, "max_backoff_sec": 3600},
          "alerts": {"enabled": true, "low_headroom_threshold_percent": 20, "notify_projected_exhaustion": true, "notify_window_reset": true, "notify_auth_expired": true, "cooldown_sec": 3600},
          "menu_bar_display_mode": "most_urgent",
          "deduplicate_shared_pools": true
        }
        """.data(using: .utf8)!

        let decoded = try HeadroomJSON.makeDecoder().decode(HeadroomConfig.self, from: legacyJSON)
        XCTAssertEqual(decoded.menuBarDisplayMode, .mostUrgent)
        XCTAssertEqual(decoded.menuBarMetricMode, .remaining)
        XCTAssertEqual(decoded.menuBarColorize, true)
        XCTAssertEqual(decoded.menuBarPinnedAccounts, [])

        let win = QuotaWindow(id: "w", label: "5h", unit: .percent, used: 64, limit: 100)
        XCTAssertEqual(MenuBarMetricMode.remaining.percentage(for: win), 36, accuracy: 0.01)
        XCTAssertEqual(MenuBarMetricMode.used.percentage(for: win), 64, accuracy: 0.01)
    }
}
