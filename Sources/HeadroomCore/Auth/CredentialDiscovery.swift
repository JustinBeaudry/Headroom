import Foundation
import SQLite3
import CryptoKit

public struct DiscoveredCredential: Sendable, Hashable {
    public let kind: CredentialKind
    public let value: String
    public let source: String
    public let metadata: [String: String]

    public init(kind: CredentialKind, value: String, source: String, metadata: [String: String] = [:]) {
        self.kind = kind
        self.value = value
        self.source = source
        self.metadata = metadata
    }
}

public protocol CredentialDiscovering: Sendable {
    func discover(for provider: ProviderID, accountLabel: String) -> [DiscoveredCredential]
    func discover(for account: AccountConfig) -> [DiscoveredCredential]
}

public extension CredentialDiscovering {
    func discover(for account: AccountConfig) -> [DiscoveredCredential] {
        discover(for: account.provider, accountLabel: account.label)
    }
}

/// Zero-password / session-reuse credential discovery:
/// Reuses existing CLI OAuth caches, local app tokens, Keychain opt-in cookies/keys, and environment variables.
public final class CredentialDiscovery: CredentialDiscovering, Sendable {
    private let secretStore: any SecretStore
    private let homeDirectory: URL
    private let environment: [String: String]
    private let readExternalKeychain: Bool

    public init(
        secretStore: any SecretStore = KeychainStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readExternalKeychain: Bool? = nil
    ) {
        self.secretStore = secretStore
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.readExternalKeychain = readExternalKeychain
            ?? (environment["HEADROOM_READ_CLAUDE_KEYCHAIN"] == "1")
    }

    public func discover(for provider: ProviderID, accountLabel: String) -> [DiscoveredCredential] {
        discover(for: AccountConfig(provider: provider, label: accountLabel))
    }

    public func discover(for account: AccountConfig) -> [DiscoveredCredential] {
        let provider = account.provider
        let accountLabel = account.label
        let allowGlobalCLI = account.resolvedAllowGlobalCLI
        let customDir: URL? = account.cliConfigDir.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        var found: [DiscoveredCredential] = []

        // 1. Account-scoped Keychain credentials stored by `headroom auth set` or Settings UI
        for kind in [CredentialKind.sessionCookie, .oauthToken, .apiKey] {
            if let secret = secretStore.getSecret(provider: provider, accountLabel: accountLabel, kind: kind),
               !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(DiscoveredCredential(kind: kind, value: secret, source: "keychain:\(kind.rawValue)"))
            }
        }

        // 2. Account-specific custom CLI config directory (e.g. ~/.claude-work, ~/.codex-work)
        if let customDir {
            switch provider {
            case .claude:
                if let token = readClaudeCodeOAuthToken(in: customDir, allowExternalKeychain: false) {
                    found.append(token)
                }
            case .codex:
                if let token = readCodexCLIOAuthToken(in: customDir) {
                    found.append(token)
                }
            case .gemini:
                if let oauth = readGeminiCLIOAuthToken(in: customDir) {
                    found.append(oauth)
                }
            case .grok, .cursor:
                break
            }
        }

        // 3. Global env vars and default local CLI/editor caches — ONLY for primary/global-enabled accounts
        //    so secondary accounts (e.g. `work`) never leak `personal` CLI credentials.
        guard allowGlobalCLI else {
            return found
        }

        switch provider {
        case .claude:
            if let cookie = env("HEADROOM_CLAUDE_SESSION_KEY") ?? env("CLAUDE_SESSION_KEY") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_CLAUDE_SESSION_KEY"))
            }
            if let token = readClaudeCodeOAuthToken(in: homeDirectory.appendingPathComponent(".claude"), allowExternalKeychain: readExternalKeychain) {
                found.append(token)
            }
            if let apiKey = env("ANTHROPIC_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:ANTHROPIC_API_KEY"))
            }

        case .codex:
            if let token = readCodexCLIOAuthToken(in: homeDirectory.appendingPathComponent(".codex")) {
                found.append(token)
            }
            if let cookie = env("HEADROOM_OPENAI_SESSION_TOKEN") ?? env("CHATGPT_SESSION_TOKEN") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_OPENAI_SESSION_TOKEN"))
            }
            if let apiKey = env("OPENAI_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:OPENAI_API_KEY"))
            }

        case .gemini:
            if let oauth = readGeminiCLIOAuthToken(in: homeDirectory.appendingPathComponent(".gemini")) {
                found.append(oauth)
            }
            if let adc = readGCloudAccessToken() {
                found.append(adc)
            }
            if let apiKey = env("GEMINI_API_KEY") ?? env("GOOGLE_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:GEMINI_API_KEY"))
            }

        case .grok:
            if let cookie = env("HEADROOM_GROK_COOKIE") ?? env("GROK_SESSION_COOKIE") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_GROK_COOKIE"))
            }
            if let apiKey = env("XAI_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:XAI_API_KEY"))
            }

        case .cursor:
            if let cookie = env("HEADROOM_CURSOR_SESSION_TOKEN") ?? env("CURSOR_SESSION_TOKEN") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_CURSOR_SESSION_TOKEN"))
            }
            if let localToken = readCursorLocalSQLiteToken() {
                found.append(localToken)
            }
        }

        return found
    }

    private func env(_ key: String) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - User-Initiated Multi-Profile Keychain Imports

    /// Computes Claude Code's macOS Keychain service name for a config directory.
    /// Default (`~/.claude` or nil) uses `"Claude Code-credentials"`; custom `CLAUDE_CONFIG_DIR`
    /// paths (e.g. `~/.claude-work`) use `"Claude Code-credentials-<sha256_prefix_8>"`.
    public static func claudeKeychainServiceName(
        for cliConfigDir: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard let raw = cliConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Claude Code-credentials"
        }
        let expanded = expandTilde(raw, homeDirectory: homeDirectory)
        let defaultPath = homeDirectory.appendingPathComponent(".claude").standardizedFileURL.path
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if normalized == defaultPath {
            return "Claude Code-credentials"
        }
        let hash = sha256Hex(normalized)
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    /// Computes Codex CLI's macOS Keychain account key (`cli|<sha256_prefix_16>`) for a `CODEX_HOME` directory
    /// when `cli_auth_credentials_store = "keyring"`.
    public static func codexKeychainAccountName(
        for cliConfigDir: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let raw = cliConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let raw, !raw.isEmpty {
            path = URL(fileURLWithPath: expandTilde(raw, homeDirectory: homeDirectory)).standardizedFileURL.path
        } else {
            path = homeDirectory.appendingPathComponent(".codex").standardizedFileURL.path
        }
        let hash = sha256Hex(path)
        return "cli|\(hash.prefix(16))"
    }

    /// Explicitly reads Claude Code's macOS Login Keychain item for the given profile directory.
    /// Call ONLY in response to an explicit user action (button click or CLI command),
    /// since macOS may display a one-time Keychain permission prompt.
    public func importClaudeCodeKeychainToken(cliConfigDir: String? = nil) -> String? {
        // First check file-based .credentials.json inside cliConfigDir if present
        if let raw = cliConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let dir = URL(fileURLWithPath: Self.expandTilde(raw, homeDirectory: homeDirectory), isDirectory: true)
            if let fileCred = readClaudeCodeOAuthToken(in: dir, allowExternalKeychain: false) {
                return fileCred.value
            }
        }
        guard let keychain = secretStore as? KeychainStore else { return nil }
        let serviceName = Self.claudeKeychainServiceName(for: cliConfigDir, homeDirectory: homeDirectory)
        guard let raw = keychain.readExternalGenericPasswordInteractive(service: serviceName),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return extractClaudeOAuthToken(from: data)
    }

    /// Explicitly imports Codex CLI credentials for a profile directory (`~/.codex` or `~/.codex-work`),
    /// checking `<dir>/auth.json` first and then macOS Keychain `"Codex Auth"` (`cli|<sha256_16>`).
    public func importCodexCLICredential(cliConfigDir: String? = nil) -> DiscoveredCredential? {
        let dirPath: String
        if let raw = cliConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            dirPath = Self.expandTilde(raw, homeDirectory: homeDirectory)
        } else {
            dirPath = homeDirectory.appendingPathComponent(".codex").path
        }
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)

        // 1. File-based auth.json
        if let fileCred = readCodexCLIOAuthToken(in: dirURL) {
            return fileCred
        }

        // 2. macOS Keychain ("Codex Auth", acct = "cli|<sha256_prefix_16>")
        guard let keychain = secretStore as? KeychainStore else { return nil }
        let acctKey = Self.codexKeychainAccountName(for: cliConfigDir, homeDirectory: homeDirectory)
        guard let raw = keychain.readExternalGenericPasswordInteractive(service: "Codex Auth", account: acctKey),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            var meta: [String: String] = [:]
            if let accountId = tokens["account_id"] as? String {
                meta["account_id"] = accountId
            }
            return DiscoveredCredential(kind: .oauthToken, value: access, source: "keychain:Codex Auth (\(acctKey))", metadata: meta)
        }
        if let access = json["access_token"] as? String, !access.isEmpty {
            return DiscoveredCredential(kind: .oauthToken, value: access, source: "keychain:Codex Auth (\(acctKey))")
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return DiscoveredCredential(kind: .apiKey, value: apiKey, source: "keychain:Codex Auth (\(acctKey))")
        }
        return nil
    }

    private static func expandTilde(_ raw: String, homeDirectory: URL) -> String {
        if raw == "~" {
            return homeDirectory.path
        }
        if raw.hasPrefix("~/") {
            return homeDirectory.path + String(raw.dropFirst())
        }
        return NSString(string: raw).expandingTildeInPath
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Claude Code CLI OAuth cache

    private func readClaudeCodeOAuthToken(in dir: URL, allowExternalKeychain: Bool) -> DiscoveredCredential? {
        let credURL = dir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: credURL),
           let token = extractClaudeOAuthToken(from: data) {
            return DiscoveredCredential(kind: .oauthToken, value: token, source: "file:\(abbreviate(credURL))")
        }

        // Check macOS Keychain item written by Claude Code CLI ("Claude Code-credentials")
        if allowExternalKeychain, let keychain = secretStore as? KeychainStore,
           let raw = keychain.readExternalGenericPassword(service: "Claude Code-credentials"),
           let data = raw.data(using: .utf8),
           let token = extractClaudeOAuthToken(from: data) {
            return DiscoveredCredential(kind: .oauthToken, value: token, source: "keychain:Claude Code-credentials")
        }

        return nil
    }

    private func extractClaudeOAuthToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let access = oauth["accessToken"] as? String, !access.isEmpty {
            return access
        }
        if let access = json["accessToken"] as? String, !access.isEmpty {
            return access
        }
        return nil
    }

    // MARK: - Codex CLI OAuth cache

    private func readCodexCLIOAuthToken(in dir: URL) -> DiscoveredCredential? {
        let authURL = dir.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let src = "file:\(abbreviate(authURL))"
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            var meta: [String: String] = [:]
            if let accountId = tokens["account_id"] as? String {
                meta["account_id"] = accountId
            }
            return DiscoveredCredential(kind: .oauthToken, value: access, source: src, metadata: meta)
        }
        if let access = json["access_token"] as? String, !access.isEmpty {
            return DiscoveredCredential(kind: .oauthToken, value: access, source: src)
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return DiscoveredCredential(kind: .apiKey, value: apiKey, source: src)
        }
        return nil
    }

    // MARK: - Gemini CLI OAuth & GCP ADC

    private func readGeminiCLIOAuthToken(in dir: URL) -> DiscoveredCredential? {
        let credsURL = dir.appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: credsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        var meta: [String: String] = ["creds_path": credsURL.path]
        if let rt = json["refresh_token"] as? String, !rt.isEmpty {
            meta["refresh_token"] = rt
        }
        if let exp = DateParsing.doubleValue(json["expiry_date"]) {
            meta["expiry_ms"] = String(Int64(exp))
        }
        return DiscoveredCredential(kind: .oauthToken, value: access, source: "file:\(abbreviate(credsURL))", metadata: meta)
    }

    private func abbreviate(_ url: URL) -> String {
        let home = homeDirectory.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    private func readGCloudAccessToken() -> DiscoveredCredential? {
        if let envToken = env("CLOUDSDK_AUTH_ACCESS_TOKEN") ?? env("GOOGLE_OAUTH_ACCESS_TOKEN") {
            return DiscoveredCredential(kind: .oauthToken, value: envToken, source: "env:GOOGLE_OAUTH_ACCESS_TOKEN")
        }
        return nil
    }

    // MARK: - Cursor local SQLite auth token (read-only)

    private func readCursorLocalSQLiteToken() -> DiscoveredCredential? {
        let dbURL = homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            let value = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return DiscoveredCredential(kind: .oauthToken, value: value, source: "sqlite:Cursor/state.vscdb")
            }
        }
        return nil
    }
}
