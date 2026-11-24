import Foundation

public struct AdapterContext: Sendable {
    public let httpClient: any HTTPClient
    public let credentials: any CredentialDiscovering
    public let logParser: any LocalLogParsing
    public let now: @Sendable () -> Date

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        credentials: any CredentialDiscovering = CredentialDiscovery(),
        logParser: any LocalLogParsing = LocalLogParser(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.httpClient = httpClient
        self.credentials = credentials
        self.logParser = logParser
        self.now = now
    }
}

/// Every provider implements a single FetchUsage(ctx) -> ProviderSnapshot contract
/// with isolated errors so one broken cookie never blocks the other four.
public protocol ProviderAdapter: Sendable {
    var provider: ProviderID { get }
    func fetchUsage(account: AccountConfig, context: AdapterContext) async -> ProviderSnapshot
}

public enum DateParsing {
    public static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    public static func parseEpochOrISO(_ value: Any?) -> Date? {
        if let str = value as? String {
            if let iso = parseISO8601(str) {
                return iso
            }
            if let num = Double(str) {
                return fromNumericEpoch(num)
            }
        }
        if let num = value as? Double {
            return fromNumericEpoch(num)
        }
        if let num = value as? Int {
            return fromNumericEpoch(Double(num))
        }
        if let num = value as? NSNumber {
            return fromNumericEpoch(num.doubleValue)
        }
        return nil
    }

    private static func fromNumericEpoch(_ num: Double) -> Date {
        if num > 10_000_000_000 {
            return Date(timeIntervalSince1970: num / 1000.0)
        }
        return Date(timeIntervalSince1970: num)
    }

    public static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    public static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
