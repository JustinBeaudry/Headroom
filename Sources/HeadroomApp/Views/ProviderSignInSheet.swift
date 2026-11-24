import SwiftUI
import WebKit
import HeadroomCore

/// Native macOS isolated WKWebView sign-in sheet.
/// Uses an ephemeral `WKWebsiteDataStore.nonPersistent()` per session so signing into
/// Work vs. Personal accounts never collides, and automatically captures the session
/// cookie without DevTools or ever touching passwords.
public struct ProviderSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    let provider: ProviderID
    let accountLabel: String
    let onCapturedCookie: (String) -> Void

    @State private var statusText: String = "Sign in below — Headroom will connect automatically."
    @State private var currentURLString: String = ""
    @State private var hasCaptured = false

    public init(
        provider: ProviderID,
        accountLabel: String,
        onCapturedCookie: @escaping (String) -> Void
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.onCapturedCookie = onCapturedCookie
    }

    public static func supportsWebSignIn(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude, .codex, .grok, .cursor: return true
        case .gemini: return false
        }
    }

    private var startURL: URL {
        switch provider {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .codex: return URL(string: "https://chatgpt.com/")!
        case .grok: return URL(string: "https://grok.com/dashboard")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .gemini: return URL(string: "https://aistudio.google.com/")!
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                ProviderBadgeIcon(provider: provider, tint: HeadroomTheme.sharedPool)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Sign in to \(provider.displayName)")
                            .font(.system(size: 13.5, weight: .semibold))
                        AccountLabelPill(label: accountLabel)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            IsolatedSignInWebView(
                provider: provider,
                startURL: startURL,
                onURLChange: { urlStr in
                    currentURLString = urlStr
                },
                onCookieFound: { cookieValue in
                    guard !hasCaptured else { return }
                    hasCaptured = true
                    statusText = "Session captured! Connecting..."
                    onCapturedCookie(cookieValue)
                    dismiss()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("Isolated private session — passwords are never stored. Only the session cookie is saved in your macOS Keychain.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 540, height: 640)
    }
}

private struct IsolatedSignInWebView: NSViewRepresentable {
    let provider: ProviderID
    let startURL: URL
    let onURLChange: (String) -> Void
    let onCookieFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider, onURLChange: onURLChange, onCookieFound: onCookieFound)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral cookie store guarantees Work & Personal sign-ins never overwrite each other.
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        context.coordinator.attach(webView: webView)
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let provider: ProviderID
        let onURLChange: (String) -> Void
        let onCookieFound: (String) -> Void
        private weak var webView: WKWebView?
        private var pollTask: Task<Void, Never>?
        private var delivered = false

        init(
            provider: ProviderID,
            onURLChange: @escaping (String) -> Void,
            onCookieFound: @escaping (String) -> Void
        ) {
            self.provider = provider
            self.onURLChange = onURLChange
            self.onCookieFound = onCookieFound
        }

        deinit {
            pollTask?.cancel()
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self, !self.delivered else { break }
                    self.inspectCookies()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let urlStr = webView.url?.absoluteString {
                onURLChange(urlStr)
            }
            inspectCookies()
        }

        // Open OAuth popup windows (e.g. SSO / Apple / Microsoft) inside the same sheet webView
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func inspectCookies() {
            guard let webView, !delivered else { return }
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let targetProvider = self.provider
            cookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in
                    guard let self, !self.delivered else { return }
                    if let extracted = Self.extractSessionCookie(for: targetProvider, from: cookies) {
                        self.delivered = true
                        self.pollTask?.cancel()
                        self.onCookieFound(extracted)
                    }
                }
            }
        }

        private static func extractSessionCookie(for provider: ProviderID, from cookies: [HTTPCookie]) -> String? {
            switch provider {
            case .claude:
                let domainCookies = cookies.filter { $0.domain.contains("claude.ai") }
                guard let session = domainCookies.first(where: { $0.name == "sessionKey" && !$0.value.isEmpty }) else {
                    return nil
                }
                // Include cf_clearance if present alongside sessionKey
                if let cf = domainCookies.first(where: { $0.name == "cf_clearance" && !$0.value.isEmpty }) {
                    return "sessionKey=\(session.value); cf_clearance=\(cf.value)"
                }
                return session.value

            case .codex:
                let domainCookies = cookies.filter { $0.domain.contains("chatgpt.com") || $0.domain.contains("openai.com") }
                if let token = domainCookies.first(where: { $0.name == "__Secure-next-auth.session-token" && !$0.value.isEmpty }) {
                    return token.value
                }
                // Handle chunked NextAuth cookies (__Secure-next-auth.session-token.0, .1, ...)
                let chunked = domainCookies
                    .filter { $0.name.hasPrefix("__Secure-next-auth.session-token.") }
                    .sorted { $0.name < $1.name }
                if !chunked.isEmpty {
                    return chunked.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                }
                return nil

            case .grok:
                let domainCookies = cookies.filter { $0.domain.contains("grok.com") || $0.domain.contains("x.ai") }
                guard let sso = domainCookies.first(where: { $0.name == "sso" && !$0.value.isEmpty }) else {
                    return nil
                }
                let relevant = domainCookies.filter { ["sso", "sso-rw", "cf_clearance"].contains($0.name) && !$0.value.isEmpty }
                if relevant.count > 1 {
                    return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                }
                return sso.value

            case .cursor:
                let domainCookies = cookies.filter { $0.domain.contains("cursor.com") || $0.domain.contains("cursor.sh") }
                if let tok = domainCookies.first(where: { $0.name == "WorkosCursorSessionToken" && !$0.value.isEmpty }) {
                    return tok.value
                }
                return nil

            case .gemini:
                return nil
            }
        }
    }
}
