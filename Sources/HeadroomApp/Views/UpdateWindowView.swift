import SwiftUI
import AppKit
import HeadroomCore

public struct UpdateWindowView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    private var release: ReleaseInfo? {
        viewModel.availableUpdate ?? viewModel.latestKnownRelease
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release {
                header(for: release)
                Divider()
                    .opacity(0.5)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("WHAT'S IN THIS RELEASE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)

                        ReleaseNotesView(markdown: release.releaseNotes)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if progressStatusText != nil {
                    Divider()
                        .opacity(0.4)
                    progressBanner
                }

                Divider()
                    .opacity(0.5)
                actionFooter(for: release)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(HeadroomTheme.reserve)
                    Text("You're up to date")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Headroom \(viewModel.currentAppVersion.tagString) is the latest version.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Check Again") {
                        Task { await viewModel.checkForUpdates(manual: true) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 460, height: 430)
    }

    private func header(for release: ReleaseInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HeadroomTheme.sharedPool.opacity(0.15))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(HeadroomTheme.sharedPool)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(release.title)
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Text("\(viewModel.currentAppVersion.tagString) -> \(release.tagName)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(HeadroomTheme.sharedPool)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(HeadroomTheme.sharedPool.opacity(0.14), in: Capsule())

                    if let published = release.publishedAt {
                        Text(published, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("ago")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var progressBanner: some View {
        HStack(spacing: 8) {
            switch viewModel.updateProgress {
            case .downloading, .verifying, .installing:
                ProgressView()
                    .controlSize(.small)
                Text(progressStatusText ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HeadroomTheme.burningFast)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(HeadroomTheme.burningFast)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035))
    }

    private var progressStatusText: String? {
        switch viewModel.updateProgress {
        case .idle: return nil
        case .downloading: return "Downloading signed release archive..."
        case .verifying: return "Verifying SHA-256 checksum & Apple Developer signature..."
        case .installing: return "Installing update & relaunching Headroom..."
        case .failed(let msg): return msg
        }
    }

    private var isInstalling: Bool {
        switch viewModel.updateProgress {
        case .downloading, .verifying, .installing: return true
        case .idle, .failed: return false
        }
    }

    private func actionFooter(for release: ReleaseInfo) -> some View {
        HStack(spacing: 10) {
            if viewModel.availableUpdate != nil {
                Button("Skip Version") {
                    viewModel.skipUpdate(release)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .disabled(isInstalling)
            }

            Spacer()

            Button("View on GitHub") {
                NSWorkspace.shared.open(release.htmlURL)
            }
            .buttonStyle(.bordered)
            .disabled(isInstalling)

            if viewModel.availableUpdate != nil {
                Button(viewModel.isRunningFromAppBundle ? "Install & Relaunch" : "Download Release") {
                    Task { await viewModel.installAvailableUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Cleanly renders GitHub Markdown release notes (headings, bullets, inline formatting).
private struct ReleaseNotesView: View {
    let markdown: String

    private struct NoteLine: Identifiable {
        let id: Int
        let kind: Kind
        let text: String

        enum Kind {
            case heading
            case bullet
            case paragraph
        }
    }

    private var parsedLines: [NoteLine] {
        var result: [NoteLine] = []
        for (idx, raw) in markdown.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" || $0 == " " })
                result.append(NoteLine(id: idx, kind: .heading, text: String(title)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let item = String(trimmed.dropFirst(2))
                result.append(NoteLine(id: idx, kind: .bullet, text: item))
            } else {
                result.append(NoteLine(id: idx, kind: .paragraph, text: trimmed))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(parsedLines) { line in
                switch line.kind {
                case .heading:
                    Text(inlineMarkdown(line.text))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 4)
                case .bullet:
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(HeadroomTheme.sharedPool)
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        Text(inlineMarkdown(line.text))
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph:
                    Text(inlineMarkdown(line.text))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
