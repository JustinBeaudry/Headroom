import Foundation

public struct AppVersion: Comparable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
        let core = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public var tagString: String {
        "v\(description)"
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// Reads the running bundle's CFBundleShortVersionString (fallback to default CLI version).
    public static func currentBundleVersion(fallback: String = "0.4.5") -> AppVersion {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let parsed = AppVersion(parsing: v) {
            return parsed
        }
        return AppVersion(parsing: fallback) ?? AppVersion(major: 0, minor: 4, patch: 5)
    }
}

public struct ReleaseInfo: Codable, Sendable, Hashable {
    public let tagName: String
    public let version: AppVersion
    public let title: String
    public let releaseNotes: String
    public let publishedAt: Date?
    public let htmlURL: URL
    public let zipAssetURL: URL?
    public let zipAssetName: String?
    public let dmgAssetURL: URL?
    public let checksumsURL: URL?

    public init(
        tagName: String,
        version: AppVersion,
        title: String,
        releaseNotes: String,
        publishedAt: Date?,
        htmlURL: URL,
        zipAssetURL: URL?,
        zipAssetName: String?,
        dmgAssetURL: URL?,
        checksumsURL: URL?
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.zipAssetURL = zipAssetURL
        self.zipAssetName = zipAssetName
        self.dmgAssetURL = dmgAssetURL
        self.checksumsURL = checksumsURL
    }

    /// Extracts concise highlight lines from Markdown release notes for notification previews.
    public var summaryHighlight: String {
        let lines = releaseNotes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.lowercased().hasPrefix("**full changelog**") && !$0.lowercased().hasPrefix("full changelog") }
        if let first = lines.first {
            let cleaned = first.replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            return cleaned
        }
        return "New improvements and fixes are ready to install."
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case updateAvailable(current: AppVersion, release: ReleaseInfo)
    case upToDate(current: AppVersion, latest: ReleaseInfo)
    case failed(String)
}

public final class UpdateChecker: Sendable {
    public static let defaultRepo = "JustinBeaudry/Headroom"

    private let repo: String
    private let httpClient: any HTTPClient
    private let token: String?

    public init(
        repo: String = UpdateChecker.defaultRepo,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        token: String? = ProcessInfo.processInfo.environment["HEADROOM_GITHUB_TOKEN"]
    ) {
        self.repo = repo
        self.httpClient = httpClient
        self.token = token
    }

    public func checkForUpdates(currentVersion: AppVersion = AppVersion.currentBundleVersion()) async -> UpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("Invalid GitHub Releases URL.")
        }

        var headers = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Headroom/\(currentVersion.description)"
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        do {
            let response = try await httpClient.send(HTTPRequest(url: url, headers: headers, timeoutInterval: 12))
            if response.statusCode == 404 {
                return .failed("No published releases found for \(repo).")
            }
            if response.statusCode == 403 {
                return .failed("GitHub API rate limit reached. Try again shortly.")
            }
            guard response.isSuccess, let json = response.jsonObject() as? [String: Any] else {
                return .failed("GitHub Releases API returned HTTP \(response.statusCode).")
            }
            guard let release = Self.parseGitHubRelease(json) else {
                return .failed("Could not parse latest GitHub Release payload.")
            }

            if release.version > currentVersion {
                return .updateAvailable(current: currentVersion, release: release)
            } else {
                return .upToDate(current: currentVersion, latest: release)
            }
        } catch {
            return .failed("Update check failed: \(error.localizedDescription)")
        }
    }

    public static func parseGitHubRelease(_ json: [String: Any]) -> ReleaseInfo? {
        guard let tagName = json["tag_name"] as? String,
              let version = AppVersion(parsing: tagName),
              let htmlStr = json["html_url"] as? String,
              let htmlURL = URL(string: htmlStr) else {
            return nil
        }

        let title = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Headroom \(tagName)"
        let rawBody = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = rawBody.isEmpty ? "See the release page on GitHub for full details." : rawBody
        let publishedAt = DateParsing.parseISO8601(json["published_at"] as? String)

        var zipURL: URL?
        var zipName: String?
        var dmgURL: URL?
        var checksumsURL: URL?

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      let dlStr = asset["browser_download_url"] as? String,
                      let dlURL = URL(string: dlStr) else {
                    continue
                }
                if name.hasPrefix("Headroom-") && name.hasSuffix(".zip") {
                    zipURL = dlURL
                    zipName = name
                } else if name.hasPrefix("Headroom-") && name.hasSuffix(".dmg") {
                    dmgURL = dlURL
                } else if name == "SHA256SUMS.txt" {
                    checksumsURL = dlURL
                }
            }
        }

        return ReleaseInfo(
            tagName: tagName,
            version: version,
            title: title,
            releaseNotes: notes,
            publishedAt: publishedAt,
            htmlURL: htmlURL,
            zipAssetURL: zipURL,
            zipAssetName: zipName,
            dmgAssetURL: dmgURL,
            checksumsURL: checksumsURL
        )
    }

    /// Parses a standard `shasum -a 256` checksum file into `[filename: lowercaseHex]`.
    public static func parseChecksums(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]).lowercased()
            let file = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            map[file] = hash
        }
        return map
    }
}
