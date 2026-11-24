import Foundation
import HeadroomCore

@main
struct HeadroomCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        let rest = Array(args.dropFirst())
        switch command {
        case "status":
            await runStatus(args: rest)
        case "poll":
            await runPoll(args: rest)
        case "pools":
            await runPools(args: rest)
        case "costs":
            runCosts(args: rest)
        case "auth":
            await runAuth(args: rest)
        case "config":
            await runConfig(args: rest)
        case "daemon":
            await runDaemon(args: rest)
        case "doctor":
            await runDoctor()
        case "-h", "--help", "help":
            printUsage()
        case "-v", "--version", "version":
            print("headroom 0.4.0")
        default:
            fputs("Unknown command: \(command)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }

    // MARK: - Commands

    static func runStatus(args: [String]) async {
        let asJSON = args.contains("--json")
        let cachedOnly = args.contains("--cached")
        let demoMode = args.contains("--demo")
        let providerFilter = optionValue(in: args, flag: "--provider").flatMap { ProviderID(rawValue: $0.lowercased()) }
        let accountFilter = optionValue(in: args, flag: "--account")

        let engine = HeadroomEngine()
        var state: HeadroomState

        if demoMode {
            state = DemoFixtures.makeDemoState()
        } else if cachedOnly, let cached = await engine.loadCachedState() {
            state = cached
        } else {
            let providers: Set<ProviderID>? = providerFilter.map { [$0] }
            let result = await engine.poll(providers: providers, force: false)
            state = result.state
        }

        var filteredSnapshots = state.snapshots
        if let providerFilter {
            filteredSnapshots = filteredSnapshots.filter { $0.provider == providerFilter }
        }
        if let accountFilter {
            filteredSnapshots = filteredSnapshots.filter { $0.accountLabel == accountFilter }
        }

        let filteredPools = state.sharedPools.filter { pool in
            if let accountFilter, pool.accountLabel != accountFilter { return false }
            if let providerFilter, !pool.memberProviders.contains(providerFilter) { return false }
            return true
        }

        let outputState = HeadroomState(
            schemaVersion: state.schemaVersion,
            updatedAt: state.updatedAt,
            snapshots: filteredSnapshots,
            sharedPools: filteredPools
        )

        if asJSON {
            printJSON(outputState)
        } else {
            printPrettyState(outputState)
        }
    }

    static func runPoll(args: [String]) async {
        let asJSON = args.contains("--json")
        let providerFilter = optionValue(in: args, flag: "--provider").flatMap { ProviderID(rawValue: $0.lowercased()) }
        let providers: Set<ProviderID>? = providerFilter.map { [$0] }

        let engine = HeadroomEngine()
        await engine.resetBackoff()
        let result = await engine.poll(providers: providers, force: true)

        if asJSON {
            printJSON(result.state)
        } else {
            printPrettyState(result.state)
            if !result.alerts.isEmpty {
                print("\nAlerts triggered (\(result.alerts.count)):")
                for alert in result.alerts {
                    print("  • [\(alert.kind.rawValue)] \(alert.title) — \(alert.body)")
                }
            }
        }
    }

    static func runPools(args: [String]) async {
        let asJSON = args.contains("--json")
        let demoMode = args.contains("--demo")
        let engine = HeadroomEngine()
        let state: HeadroomState
        if demoMode {
            state = DemoFixtures.makeDemoState()
        } else if let cached = await engine.loadCachedState() {
            state = cached
        } else {
            state = await engine.poll(force: false).state
        }

        if asJSON {
            printJSON(state.sharedPools)
            return
        }

        if state.sharedPools.isEmpty {
            print("No linked shared pools detected (e.g. unified X Subscription Cursor + Grok).")
            return
        }

        print("Shared Pools (\(state.sharedPools.count)):")
        for pool in state.sharedPools {
            let members = pool.memberProviders.map(\.displayName).joined(separator: " + ")
            let win = pool.canonicalWindow
            print("\n  \(pool.label) [\(pool.accountLabel)] — \(members)")
            print("    Pool: \(formatBar(usedPercent: win.usedPercent)) \(String(format: "%.0f%% left", win.headroomPercent)) | \(win.paceStatus.displayLabel) | Resets in \(PaceCalculator.formatCountdown(until: win.resetsAt))")
            for sup in pool.supplementaryWindows {
                print("    + \(sup.provider.displayName) \(sup.window.label): \(sup.window.formattedUsage)")
            }
        }
    }

    static func runCosts(args: [String]) {
        let asJSON = args.contains("--json")
        let days = Int(optionValue(in: args, flag: "--days") ?? "7") ?? 7
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let parser = LocalLogParser()

        let summaries = [
            parser.parseClaudeLogs(since: since),
            parser.parseCodexLogs(since: since),
            parser.parseGeminiLogs(since: since)
        ]

        if asJSON {
            printJSON(summaries)
            return
        }

        print("Local CLI Token & Cost Estimate (last \(days)d)")
        print(String(repeating: "─", count: 66))
        var totalCost = 0.0
        for s in summaries {
            totalCost += s.estimatedCostUSD
            let inStr = QuotaWindow.formatCompactNumber(Double(s.inputTokens))
            let outStr = QuotaWindow.formatCompactNumber(Double(s.outputTokens))
            let cacheStr = QuotaWindow.formatCompactNumber(Double(s.cacheReadTokens))
            print(String(
                format: "  %-8s  %4d req  | in %-6s  out %-6s  cache %-6s  | $%.2f",
                (s.provider.displayName as NSString).utf8String!,
                s.requestCount,
                (inStr as NSString).utf8String!,
                (outStr as NSString).utf8String!,
                (cacheStr as NSString).utf8String!,
                s.estimatedCostUSD
            ))
        }
        print(String(repeating: "─", count: 66))
        print(String(format: "  Total estimated local CLI spend: $%.2f", totalCost))
    }

    static func runAuth(args: [String]) async {
        guard let sub = args.first else {
            print("Usage: headroom auth <status|set|clear> ...")
            return
        }
        let store = KeychainStore()
        let configStore = ConfigStore()
        let config = await configStore.load()

        switch sub {
        case "status":
            let discovery = CredentialDiscovery(secretStore: store)
            print("Credential Discovery Status (Zero-Password / Session Reuse)")
            print(String(repeating: "─", count: 66))
            for account in config.accounts {
                let creds = discovery.discover(for: account.provider, accountLabel: account.label)
                let label = "\(account.provider.displayName) (\(account.label))"
                if creds.isEmpty {
                    print("  • \(label): none detected")
                } else {
                    let sources = creds.map { "\($0.kind.rawValue) via \($0.source)" }.joined(separator: ", ")
                    print("  ✓ \(label): \(sources)")
                }
            }

        case "set":
            guard args.count >= 2, let provider = ProviderID(rawValue: args[1].lowercased()) else {
                fputs("Usage: headroom auth set <claude|codex|gemini|grok|cursor> [--account personal] [--kind cookie|token|apikey] [--value <secret> | --stdin]\n", stderr)
                exit(1)
            }
            let account = optionValue(in: args, flag: "--account") ?? "personal"
            let kindStr = optionValue(in: args, flag: "--kind") ?? "cookie"
            guard let kind = CredentialKind(rawValue: kindStr.lowercased()) else {
                fputs("Invalid --kind '\(kindStr)'. Expected: cookie, token, or apikey.\n", stderr)
                exit(1)
            }
            var value = optionValue(in: args, flag: "--value")
            if value == nil && args.contains("--stdin") {
                value = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if value == nil {
                fputs("Paste \(kind.rawValue) for \(provider.displayName) (\(account)) and press Enter: ", stderr)
                value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let secret = value, !secret.isEmpty else {
                fputs("No credential provided; aborting.\n", stderr)
                exit(1)
            }
            do {
                try store.setSecret(secret, provider: provider, accountLabel: account, kind: kind)
                print("Saved \(kind.rawValue) for \(provider.displayName) (\(account)) in macOS Keychain.")
            } catch {
                fputs("Failed to save credential: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "clear":
            guard args.count >= 2, let provider = ProviderID(rawValue: args[1].lowercased()) else {
                fputs("Usage: headroom auth clear <claude|codex|gemini|grok|cursor> [--account personal]\n", stderr)
                exit(1)
            }
            let account = optionValue(in: args, flag: "--account") ?? "personal"
            for kind in CredentialKind.allCases {
                try? store.deleteSecret(provider: provider, accountLabel: account, kind: kind)
            }
            print("Cleared Keychain credentials for \(provider.displayName) (\(account)).")

        default:
            fputs("Unknown auth subcommand: \(sub)\n", stderr)
            exit(1)
        }
    }

    static func runConfig(args: [String]) async {
        let store = ConfigStore()
        let sub = args.first ?? "show"

        switch sub {
        case "show":
            let config = await store.load()
            printJSON(config)

        case "init":
            let config = HeadroomConfig()
            do {
                try await store.save(config)
                print("Wrote default configuration to \(store.path)")
            } catch {
                fputs("Failed to write config: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "add-account":
            guard args.count >= 3, let provider = ProviderID(rawValue: args[1].lowercased()) else {
                fputs("Usage: headroom config add-account <provider> <label>\n", stderr)
                exit(1)
            }
            let label = args[2]
            var config = await store.load()
            if !config.accounts.contains(where: { $0.provider == provider && $0.label == label }) {
                config.accounts.append(AccountConfig(provider: provider, label: label, enabled: true))
                try? await store.save(config)
                print("Added account \(provider.displayName) (\(label)).")
            } else {
                print("Account \(provider.displayName) (\(label)) already exists.")
            }

        case "set-gemini-lane":
            guard args.count >= 2, let lane = GeminiLane(rawValue: args[1].lowercased()) else {
                fputs("Usage: headroom config set-gemini-lane <auto|cli|gcp_quota|api_key> [--account personal]\n", stderr)
                exit(1)
            }
            let label = optionValue(in: args, flag: "--account") ?? "personal"
            var config = await store.load()
            if let idx = config.accounts.firstIndex(where: { $0.provider == .gemini && $0.label == label }) {
                config.accounts[idx].geminiLane = lane
                try? await store.save(config)
                print("Set Gemini (\(label)) lane to \(lane.displayName).")
            } else {
                fputs("No Gemini account with label '\(label)' found.\n", stderr)
                exit(1)
            }

        default:
            fputs("Unknown config subcommand: \(sub)\n", stderr)
            exit(1)
        }
    }

    static func runDaemon(args: [String]) async {
        let runOnce = args.contains("--once")
        let engine = HeadroomEngine()
        print("Headroom daemon started. Cache path: \(HeadroomPaths.stateFileURL.path)")

        while true {
            let result = await engine.poll(force: false)
            let active = await engine.isUserActive()
            let interval = await engine.nextRecommendedInterval()
            let ts = ISO8601DateFormatter().string(from: result.state.updatedAt)
            print("[\(ts)] Polled \(result.state.snapshots.count) accounts (mode: \(active ? "active" : "idle"), next in \(Int(interval))s)")
            for alert in result.alerts {
                print("  ALERT [\(alert.kind.rawValue)]: \(alert.title) — \(alert.body)")
            }
            if runOnce { break }
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }

    static func runDoctor() async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        print("Headroom Doctor")
        print(String(repeating: "─", count: 66))
        print("  App Support Dir : \(HeadroomPaths.appSupportDirectory.path)")
        print("  State Cache     : \(fm.fileExists(atPath: HeadroomPaths.stateFileURL.path) ? "present" : "not created yet")")
        print("  Config File     : \(fm.fileExists(atPath: HeadroomPaths.configFileURL.path) ? "present" : "using defaults")")

        let probes: [(String, String)] = [
            ("Claude Code logs", ".claude/projects"),
            ("Claude Code creds", ".claude/.credentials.json"),
            ("Codex CLI auth", ".codex/auth.json"),
            ("Codex CLI sessions", ".codex/sessions"),
            ("Gemini CLI oauth", ".gemini/oauth_creds.json"),
            ("Cursor SQLite DB", "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        ]
        print("\nLocal Integration Probes:")
        for (name, rel) in probes {
            let exists = fm.fileExists(atPath: home.appendingPathComponent(rel).path)
            print("  \(exists ? "✓" : "·") \(name) (~/\(rel))")
        }
    }

    // MARK: - Formatting Helpers

    static func printPrettyState(_ state: HeadroomState) {
        print("Headroom — AI Quota & Pace Telemetry")
        print("Updated: \(ISO8601DateFormatter().string(from: state.updatedAt))")
        print(String(repeating: "─", count: 72))

        if !state.sharedPools.isEmpty {
            for pool in state.sharedPools {
                let members = pool.memberProviders.map(\.displayName).joined(separator: " + ")
                let w = pool.canonicalWindow
                print("\n[\(pool.label)] (\(members) • \(pool.accountLabel))")
                printWindowLine(w)
                for sup in pool.supplementaryWindows {
                    print("    + \(sup.provider.displayName) \(sup.window.label): \(formatBar(usedPercent: sup.window.usedPercent, width: 12)) \(sup.window.formattedUsage)")
                }
            }
        }

        let standalone = PoolDeduplicator.standaloneSnapshots(from: state.snapshots, sharedPools: state.sharedPools)
        for snap in standalone {
            let statusBadge = snap.status.rawValue.uppercased()
            let costNote = snap.estimatedLocalCostUSD.map { String(format: " | local ~$%.2f", $0) } ?? ""
            print("\n[\(snap.provider.displayName)] (\(snap.accountLabel)) — \(statusBadge)\(costNote)")
            if snap.windows.isEmpty {
                if let msg = snap.message {
                    print("    \(msg)")
                }
            } else {
                for w in snap.windows {
                    printWindowLine(w)
                }
                if let msg = snap.message, snap.status != .ok {
                    print("    Note: \(msg)")
                }
            }
        }
        print("")
    }

    static func printWindowLine(_ w: QuotaWindow) {
        let bar = formatBar(usedPercent: w.usedPercent, width: 16)
        let countdown = PaceCalculator.formatCountdown(until: w.resetsAt)
        let headroom = String(format: "%3.0f%% left", w.headroomPercent)
        let pace = w.paceStatus.displayLabel
        var projection = ""
        if let detail = w.paceDetail, detail.willExhaustBeforeReset, let exhaust = detail.projectedExhaustionAt {
            projection = " (⚠ runs out in ~\(PaceCalculator.formatCountdown(until: exhaust)))"
        }
        print("    \(w.label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(bar) \(headroom)  [\(pace)]  reset \(countdown)\(projection)")
    }

    static func formatBar(usedPercent: Double, width: Int = 16) -> String {
        let clamped = min(max(usedPercent, 0), 100)
        let filled = Int((clamped / 100.0 * Double(width)).rounded())
        let empty = max(0, width - filled)
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = HeadroomJSON.makeEncoder(prettyPrinted: true)
        if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func optionValue(in args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    static func printUsage() {
        print("""
        headroom — Native macOS AI quota & pace telemetry CLI

        USAGE:
          headroom status [--json] [--provider <name>] [--account <label>] [--cached] [--demo]
          headroom poll [--provider <name>] [--json]
          headroom pools [--json] [--demo]
          headroom costs [--days <n>] [--json]
          headroom auth <status|set|clear> ...
          headroom config <show|init|add-account|set-gemini-lane> ...
          headroom daemon [--once]
          headroom doctor

        PROVIDERS:
          claude, codex, gemini, grok, cursor
        """)
    }
}
