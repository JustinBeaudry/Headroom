import SwiftUI
import HeadroomCore

public struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    let privacyMode: Bool
    let onReauth: () -> Void
    let onRefresh: () -> Void

    public init(
        snapshot: ProviderSnapshot,
        privacyMode: Bool,
        onReauth: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.privacyMode = privacyMode
        self.onReauth = onReauth
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(snapshot.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(privacyMode ? "••••" : snapshot.accountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                Spacer()

                if let cost = snapshot.estimatedLocalCostUSD, !privacyMode {
                    Text(String(format: "~$%.2f", cost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                StatusPill(status: snapshot.status)
            }

            if snapshot.status == .authExpired {
                HStack(spacing: 8) {
                    Text(snapshot.message ?? "Session cookie or token expired.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Re-auth") {
                        onReauth()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else if snapshot.windows.isEmpty {
                Text(snapshot.message ?? "Not configured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.windows) { window in
                    QuotaWindowRow(window: window, privacyMode: privacyMode)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .ok:
            guard let primary = snapshot.primaryWindow else { return .green }
            return paceColor(primary.paceStatus, headroom: primary.headroomPercent)
        case .stale: return .orange
        case .authExpired, .incident: return .red
        case .unconfigured: return .gray
        }
    }
}

public struct SharedPoolCardView: View {
    let pool: SharedPoolGroup
    let privacyMode: Bool

    public init(pool: SharedPoolGroup, privacyMode: Bool) {
        self.pool = pool
        self.privacyMode = privacyMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 13))
                Text(pool.label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(pool.memberProviders) { provider in
                        Text(provider.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.14), in: Capsule())
                    }
                }
            }

            QuotaWindowRow(window: pool.canonicalWindow, privacyMode: privacyMode)

            if !pool.supplementaryWindows.isEmpty {
                Divider()
                    .opacity(0.4)
                ForEach(pool.supplementaryWindows) { sup in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(sup.provider.displayName) • \(sup.window.label)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        QuotaWindowRow(window: sup.window, privacyMode: privacyMode, hideTitle: true)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }
}

public struct QuotaWindowRow: View {
    let window: QuotaWindow
    let privacyMode: Bool
    var hideTitle: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !hideTitle {
                    Text(window.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
                if privacyMode {
                    Text("••% left")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(window.headroomPercent.rounded()))% left")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(paceColor(window.paceStatus, headroom: window.headroomPercent))
                    Text("(\(window.formattedUsage))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Dual-track bar: fill shows % used, vertical tick shows % of reset window elapsed
            GeometryReader { geo in
                let usedFrac = privacyMode ? 0.45 : min(max(window.usedPercent / 100.0, 0), 1)
                let elapsedFrac = min(max((window.paceDetail?.elapsedPercent ?? 0) / 100.0, 0), 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(privacyMode ? Color.secondary.opacity(0.4) : paceColor(window.paceStatus, headroom: window.headroomPercent))
                        .frame(width: geo.size.width * usedFrac)
                    if !privacyMode && elapsedFrac > 0.02 && elapsedFrac < 0.99 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 1.5, height: 10)
                            .offset(x: geo.size.width * elapsedFrac - 0.75)
                    }
                }
            }
            .frame(height: 6)

            HStack {
                if !privacyMode {
                    Text(window.paceStatus.displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(paceColor(window.paceStatus, headroom: window.headroomPercent))
                    if let detail = window.paceDetail,
                       detail.willExhaustBeforeReset,
                       let eta = detail.projectedExhaustionAt {
                        Text("• out in ~\(PaceCalculator.formatCountdown(until: eta))")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("Hidden")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Resets \(PaceCalculator.formatCountdown(until: window.resetsAt))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusPill: View {
    let status: SnapshotStatus

    var body: some View {
        switch status {
        case .ok:
            EmptyView()
        case .stale:
            pill("STALE", color: .orange)
        case .authExpired:
            pill("AUTH EXPIRED", color: .red)
        case .incident:
            pill("INCIDENT", color: .red)
        case .unconfigured:
            pill("SETUP", color: .secondary)
        }
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

func paceColor(_ pace: PaceStatus, headroom: Double) -> Color {
    if headroom <= 15 || pace == .burningFast {
        return .red
    } else if headroom <= 35 || pace == .onTrack {
        return .orange
    } else {
        return .green
    }
}
