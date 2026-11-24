import Foundation
import SQLite3

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
        var found: [DiscoveredCredential] = []

        // 1. Explicit Keychain credentials stored by `headroom auth set`
        for kind in [CredentialKind.sessionCookie, .oauthToken, .apiKey] {
            if let secret = secretStore.getSecret(provider: provider, accountLabel: accountLabel, kind: kind),
               !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(DiscoveredCredential(kind: kind, value: secret, source: "keychain:\(kind.rawValue)"))
            }
        }

        // 2. Provider-specific environment variables and local CLI/editor caches
        switch provider {
        case .claude:
            if let cookie = env("HEADROOM_CLAUDE_SESSION_KEY") ?? env("CLAUDE_SESSION_KEY") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_CLAUDE_SESSION_KEY"))
            }
            if let token = readClaudeCodeOAuthToken() {
                found.append(token)
            }
            if let apiKey = env("ANTHROPIC_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:ANTHROPIC_API_KEY"))
            }

        case .codex:
            if let token = readCodexCLIOAuthToken() {
                found.append(token)
            }
            if let cookie = env("HEADROOM_OPENAI_SESSION_TOKEN") ?? env("CHATGPT_SESSION_TOKEN") {
                found.append(DiscoveredCredential(kind: .sessionCookie, value: cookie, source: "env:HEADROOM_OPENAI_SESSION_TOKEN"))
            }
            if let apiKey = env("OPENAI_API_KEY") {
                found.append(DiscoveredCredential(kind: .apiKey, value: apiKey, source: "env:OPENAI_API_KEY"))
            }

        case .gemini:
            if let oauth = readGeminiCLIOAuthToken() {
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

    // MARK: - Claude Code CLI OAuth cache

    private func readClaudeCodeOAuthToken() -> DiscoveredCredential? {
        // Check ~/.claude/.credentials.json first
        let credURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credURL),
           let token = extractClaudeOAuthToken(from: data) {
            return DiscoveredCredential(kind: .oauthToken, value: token, source: "file:~/.claude/.credentials.json")
        }

        // Check macOS Keychain item written by Claude Code CLI ("Claude Code-credentials")
        if readExternalKeychain, let keychain = secretStore as? KeychainStore,
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

    private func readCodexCLIOAuthToken() -> DiscoveredCredential? {
        let authURL = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            var meta: [String: String] = [:]
            if let accountId = tokens["account_id"] as? String {
                meta["account_id"] = accountId
            }
            return DiscoveredCredential(kind: .oauthToken, value: access, source: "file:~/.codex/auth.json", metadata: meta)
        }
        if let access = json["access_token"] as? String, !access.isEmpty {
            return DiscoveredCredential(kind: .oauthToken, value: access, source: "file:~/.codex/auth.json")
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return DiscoveredCredential(kind: .apiKey, value: apiKey, source: "file:~/.codex/auth.json")
        }
        return nil
    }

    // MARK: - Gemini CLI OAuth & GCP ADC

    private func readGeminiCLIOAuthToken() -> DiscoveredCredential? {
        let credsURL = homeDirectory.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: credsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        return DiscoveredCredential(kind: .oauthToken, value: access, source: "file:~/.gemini/oauth_creds.json")
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
