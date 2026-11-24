import Foundation

public struct LocalUsageSummary: Codable, Sendable, Hashable {
    public let provider: ProviderID
    public let requestCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    public let earliestEvent: Date?
    public let latestEvent: Date?

    enum CodingKeys: String, CodingKey {
        case provider
        case requestCount = "request_count"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case estimatedCostUSD = "estimated_cost_usd"
        case earliestEvent = "earliest_event"
        case latestEvent = "latest_event"
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }

    public init(
        provider: ProviderID,
        requestCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        earliestEvent: Date?,
        latestEvent: Date?
    ) {
        self.provider = provider
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.earliestEvent = earliestEvent
        self.latestEvent = latestEvent
    }
}

public protocol LocalLogParsing: Sendable {
    func parseClaudeLogs(since: Date) -> LocalUsageSummary
    func parseCodexLogs(since: Date) -> LocalUsageSummary
    func parseGeminiLogs(since: Date) -> LocalUsageSummary
}

/// Parses local CLI JSONL / JSON session logs for Claude Code, Codex CLI, and Gemini CLI
/// to estimate token usage, request counts, and dollar costs offline.
public final class LocalLogParser: LocalLogParsing, Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func parseClaudeLogs(since: Date) -> LocalUsageSummary {
        let projectsDir = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let files = collectFiles(in: projectsDir, pathExtension: "jsonl", modifiedSince: since)
        return parseJSONLFiles(files, provider: .claude, since: since)
    }

    public func parseCodexLogs(since: Date) -> LocalUsageSummary {
        let sessionsDir = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = collectFiles(in: sessionsDir, pathExtension: "jsonl", modifiedSince: since)
        return parseJSONLFiles(files, provider: .codex, since: since)
    }

    public func parseGeminiLogs(since: Date) -> LocalUsageSummary {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
        let jsonlFiles = collectFiles(in: geminiDir.appendingPathComponent("sessions"), pathExtension: "jsonl", modifiedSince: since)
        let tmpJsonFiles = collectFiles(in: geminiDir.appendingPathComponent("tmp"), pathExtension: "json", modifiedSince: since)

        let jsonlSummary = parseJSONLFiles(jsonlFiles, provider: .gemini, since: since)
        let tmpSummary = parseGeminiTmpJSONFiles(tmpJsonFiles, since: since)

        let earliest = [jsonlSummary.earliestEvent, tmpSummary.earliestEvent].compactMap { $0 }.min()
        let latest = [jsonlSummary.latestEvent, tmpSummary.latestEvent].compactMap { $0 }.max()

        return LocalUsageSummary(
            provider: .gemini,
            requestCount: jsonlSummary.requestCount + tmpSummary.requestCount,
            inputTokens: jsonlSummary.inputTokens + tmpSummary.inputTokens,
            outputTokens: jsonlSummary.outputTokens + tmpSummary.outputTokens,
            cacheReadTokens: jsonlSummary.cacheReadTokens + tmpSummary.cacheReadTokens,
            estimatedCostUSD: round4(jsonlSummary.estimatedCostUSD + tmpSummary.estimatedCostUSD),
            earliestEvent: earliest,
            latestEvent: latest
        )
    }

    public func parseJSONLData(_ data: Data, provider: ProviderID, since: Date) -> LocalUsageSummary {
        guard let text = String(data: data, encoding: .utf8) else {
            return emptySummary(for: provider)
        }
        var requestCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var totalCost = 0.0
        var earliest: Date?
        var latest: Date?

        struct UsageRecord {
            let inputTokens: Int
            let outputTokens: Int
            let cacheReadTokens: Int
            let cost: Double
            let eventDate: Date?
        }

        var keyedRecords: [String: UsageRecord] = [:]
        var unkeyedRecords: [UsageRecord] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            // Fast pre-filter: skip large tool-output/text lines that have no token usage fields.
            guard rawLine.contains("usage") || rawLine.contains("token") else {
                continue
            }
            guard let lineData = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let eventDate = extractTimestamp(from: obj)
            if let eventDate, eventDate < since {
                continue
            }

            guard let usage = extractUsageObject(from: obj) else {
                continue
            }

            let rawInTok = intValue(usage["input_tokens"] ?? usage["prompt_tokens"] ?? usage["promptTokenCount"])
            let outTok = intValue(usage["output_tokens"] ?? usage["completion_tokens"] ?? usage["candidatesTokenCount"])
            let cacheTok = intValue(
                usage["cache_read_input_tokens"]
                    ?? usage["cached_input_tokens"]
                    ?? usage["cached_tokens"]
                    ?? usage["cachedContentTokenCount"]
            )
            // OpenAI/Codex `input_tokens` includes `cached_input_tokens`; avoid double-counting.
            let inTok = (usage["cached_input_tokens"] != nil) ? max(0, rawInTok - cacheTok) : rawInTok

            if inTok == 0 && outTok == 0 && cacheTok == 0 {
                continue
            }

            let model = extractModelName(from: obj) ?? provider.rawValue
            let cost = estimateCost(provider: provider, model: model, inputTokens: inTok, outputTokens: outTok, cacheReadTokens: cacheTok)
            let record = UsageRecord(
                inputTokens: inTok,
                outputTokens: outTok,
                cacheReadTokens: cacheTok,
                cost: cost,
                eventDate: eventDate
            )

            // Deduplicate streaming JSONL updates that repeat the same requestId / message.id,
            // keeping the final chunk with the completed output_tokens count.
            if let dedupId = extractRequestDedupID(from: obj) {
                keyedRecords[dedupId] = record
            } else {
                unkeyedRecords.append(record)
            }
        }

        for rec in keyedRecords.values {
            requestCount += 1
            inputTokens += rec.inputTokens
            outputTokens += rec.outputTokens
            cacheReadTokens += rec.cacheReadTokens
            totalCost += rec.cost
            if let d = rec.eventDate {
                earliest = earliest.map { min($0, d) } ?? d
                latest = latest.map { max($0, d) } ?? d
            }
        }
        for rec in unkeyedRecords {
            requestCount += 1
            inputTokens += rec.inputTokens
            outputTokens += rec.outputTokens
            cacheReadTokens += rec.cacheReadTokens
            totalCost += rec.cost
            if let d = rec.eventDate {
                earliest = earliest.map { min($0, d) } ?? d
                latest = latest.map { max($0, d) } ?? d
            }
        }

        return LocalUsageSummary(
            provider: provider,
            requestCount: requestCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            estimatedCostUSD: round4(totalCost),
            earliestEvent: earliest,
            latestEvent: latest
        )
    }

    private func parseJSONLFiles(_ files: [URL], provider: ProviderID, since: Date) -> LocalUsageSummary {
        var requestCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cost = 0.0
        var earliest: Date?
        var latest: Date?

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let sub = parseJSONLData(data, provider: provider, since: since)
            requestCount += sub.requestCount
            inputTokens += sub.inputTokens
            outputTokens += sub.outputTokens
            cacheReadTokens += sub.cacheReadTokens
            cost += sub.estimatedCostUSD
            if let e = sub.earliestEvent { earliest = earliest.map { min($0, e) } ?? e }
            if let l = sub.latestEvent { latest = latest.map { max($0, l) } ?? l }
        }

        return LocalUsageSummary(
            provider: provider,
            requestCount: requestCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            estimatedCostUSD: round4(cost),
            earliestEvent: earliest,
            latestEvent: latest
        )
    }

    private func parseGeminiTmpJSONFiles(_ files: [URL], since: Date) -> LocalUsageSummary {
        var requestCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cost = 0.0
        var earliest: Date?
        var latest: Date?

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let messages = obj["messages"] as? [[String: Any]] {
                for msg in messages {
                    let eventDate = extractTimestamp(from: msg) ?? extractTimestamp(from: obj)
                    if let eventDate, eventDate < since { continue }
                    guard let tokens = msg["tokens"] as? [String: Any] ?? extractUsageObject(from: msg) else { continue }
                    let inTok = intValue(tokens["input"] ?? tokens["input_tokens"] ?? tokens["promptTokenCount"])
                    let outTok = intValue(tokens["output"] ?? tokens["output_tokens"] ?? tokens["candidatesTokenCount"])
                    let cacheTok = intValue(tokens["cached"] ?? tokens["cachedContentTokenCount"])
                    guard inTok > 0 || outTok > 0 else { continue }

                    let model = (msg["model"] as? String) ?? "gemini-2.5-pro"
                    requestCount += 1
                    inputTokens += inTok
                    outputTokens += outTok
                    cacheReadTokens += cacheTok
                    cost += estimateCost(provider: .gemini, model: model, inputTokens: inTok, outputTokens: outTok, cacheReadTokens: cacheTok)
                    if let eventDate {
                        earliest = earliest.map { min($0, eventDate) } ?? eventDate
                        latest = latest.map { max($0, eventDate) } ?? eventDate
                    }
                }
            }
        }

        return LocalUsageSummary(
            provider: .gemini,
            requestCount: requestCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            estimatedCostUSD: round4(cost),
            earliestEvent: earliest,
            latestEvent: latest
        )
    }

    private func collectFiles(in directory: URL, pathExtension: String, modifiedSince: Date) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == pathExtension else { continue }
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
               values.isRegularFile == true {
                if let mtime = values.contentModificationDate, mtime >= modifiedSince {
                    results.append(url)
                }
            }
        }
        return results
    }

    private func extractUsageObject(from obj: [String: Any]) -> [String: Any]? {
        if let usage = obj["usage"] as? [String: Any] {
            return usage
        }
        if let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
            return usage
        }
        if let payload = obj["payload"] as? [String: Any] {
            if let info = payload["info"] as? [String: Any],
               let lastUsage = info["last_token_usage"] as? [String: Any] {
                return lastUsage
            }
            if let usage = payload["usage"] as? [String: Any] {
                return usage
            }
        }
        if let metadata = obj["usageMetadata"] as? [String: Any] {
            return metadata
        }
        return nil
    }

    private func extractModelName(from obj: [String: Any]) -> String? {
        if let model = obj["model"] as? String { return model }
        if let msg = obj["message"] as? [String: Any], let model = msg["model"] as? String { return model }
        if let payload = obj["payload"] as? [String: Any], let model = payload["model"] as? String { return model }
        return nil
    }

    private func extractRequestDedupID(from obj: [String: Any]) -> String? {
        if let reqId = obj["requestId"] as? String, !reqId.isEmpty { return reqId }
        if let msg = obj["message"] as? [String: Any], let msgId = msg["id"] as? String, !msgId.isEmpty {
            return msgId
        }
        return nil
    }

    private func extractTimestamp(from obj: [String: Any]) -> Date? {
        let raw = obj["timestamp"] ?? obj["created_at"] ?? obj["createdAt"] ?? obj["time"]
        if let str = raw as? String {
            return DateParsing.parseISO8601(str)
        }
        if let num = raw as? Double {
            return num > 10_000_000_000 ? Date(timeIntervalSince1970: num / 1000.0) : Date(timeIntervalSince1970: num)
        }
        if let num = raw as? Int {
            let d = Double(num)
            return d > 10_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0) : Date(timeIntervalSince1970: d)
        }
        return nil
    }

    private func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// Rough per-million-token blended USD pricing table for local cost estimation.
    public func estimateCost(
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int
    ) -> Double {
        let lower = model.lowercased()
        let (inRate, outRate, cacheRate): (Double, Double, Double)
        switch provider {
        case .claude:
            if lower.contains("opus") {
                (inRate, outRate, cacheRate) = (15.0, 75.0, 1.5)
            } else if lower.contains("haiku") {
                (inRate, outRate, cacheRate) = (0.8, 4.0, 0.08)
            } else {
                (inRate, outRate, cacheRate) = (3.0, 15.0, 0.3)
            }
        case .codex:
            if lower.contains("mini") {
                (inRate, outRate, cacheRate) = (0.4, 1.6, 0.1)
            } else {
                (inRate, outRate, cacheRate) = (2.5, 10.0, 0.625)
            }
        case .gemini:
            if lower.contains("flash") {
                (inRate, outRate, cacheRate) = (0.15, 0.6, 0.0375)
            } else {
                (inRate, outRate, cacheRate) = (1.25, 10.0, 0.3125)
            }
        case .grok:
            (inRate, outRate, cacheRate) = (3.0, 15.0, 0.75)
        case .cursor:
            (inRate, outRate, cacheRate) = (3.0, 15.0, 0.3)
        }

        let perMillion = 1_000_000.0
        return (Double(inputTokens) / perMillion) * inRate
            + (Double(outputTokens) / perMillion) * outRate
            + (Double(cacheReadTokens) / perMillion) * cacheRate
    }

    private func emptySummary(for provider: ProviderID) -> LocalUsageSummary {
        LocalUsageSummary(
            provider: provider,
            requestCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0,
            earliestEvent: nil,
            latestEvent: nil
        )
    }

    private func round4(_ value: Double) -> Double {
        (value * 10_000.0).rounded() / 10_000.0
    }
}
