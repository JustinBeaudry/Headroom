import SwiftUI
import HeadroomCore

public struct AccountLabelPill: View {
    let label: String
    let privacyMode: Bool

    public init(label: String, privacyMode: Bool = false) {
        self.label = label
        self.privacyMode = privacyMode
    }

    private var tint: Color {
        switch label.lowercased() {
        case "work": return Color(red: 0.39, green: 0.40, blue: 0.95)     // Indigo
        case "personal": return Color(red: 0.08, green: 0.72, blue: 0.65) // Teal
        default: return .secondary
        }
    }

    public var body: some View {
        Text(privacyMode ? "••••" : label.capitalized)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(privacyMode ? .secondary : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background((privacyMode ? Color.secondary : tint).opacity(0.14), in: Capsule())
    }
}

public struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    let privacyMode: Bool
    let showAccountLabel: Bool
    let onReauth: () -> Void
    let onConfigure: () -> Void
    let onRefresh: () -> Void

    @State private var isExpanded = false
    @State private var isHovered = false

    public init(
        snapshot: ProviderSnapshot,
        privacyMode: Bool,
        showAccountLabel: Bool = false,
        onReauth: @escaping () -> Void,
        onConfigure: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.privacyMode = privacyMode
        self.showAccountLabel = showAccountLabel
        self.onReauth = onReauth
        self.onConfigure = onConfigure
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header row: Provider identity + account badge + single-window hero or clean disclosure
            HStack(spacing: 8) {
                ProviderBadgeIcon(provider: snapshot.provider, tint: accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if showAccountLabel {
                            AccountLabelPill(label: snapshot.accountLabel, privacyMode: privacyMode)
                        }
                    }

                    if let subtitle = cardSubtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                headerTrailingView
            }

            // Content body: Windows, auth recovery, or local telemetry fallback
            if snapshot.status == .authExpired {
                HStack(spacing: 8) {
                    Text(snapshot.message ?? "Session expired. Re-authenticate to resume live tracking.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Sign In") {
                        onReauth()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if snapshot.windows.isEmpty {
                localTelemetryOrNoticeView
            } else {
                VStack(spacing: 9) {
                    ForEach(snapshot.windows) { window in
                        QuotaWindowRow(
                            window: window,
                            privacyMode: privacyMode,
                            showHeaderHero: snapshot.windows.count > 1
                        )
                    }
                }
            }

            if isExpanded {
                Divider()
                    .opacity(0.35)
                expandedDetailsView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10.5)
        .background(
            RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.065 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    snapshot.status == .authExpired
                        ? HeadroomTheme.burningFast.opacity(0.35)
                        : Color.primary.opacity(isHovered ? 0.13 : 0.075),
                    lineWidth: 0.85
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var headerTrailingView: some View {
        if snapshot.status == .authExpired {
            StatusBadge(text: "Auth Expired", color: HeadroomTheme.burningFast)
        } else if snapshot.status == .incident {
            StatusBadge(text: "Offline", color: HeadroomTheme.burningFast)
        } else if snapshot.windows.count == 1, let single = snapshot.windows.first {
            if privacyMode {
                Text("••% left")
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(single.headroomPercent.rounded()))% left")
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(HeadroomTheme.statusColor(for: single.paceStatus, headroom: single.headroomPercent))
            }
        } else if snapshot.status == .stale && snapshot.windows.isEmpty {
            StatusBadge(text: "Local Only", color: HeadroomTheme.stale)
        } else {
            // Multi-window cards show exact remaining % on each window row; keep header calm & unambiguous.
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var cardSubtitle: String? {
        if let billing = snapshot.billingModel {
            switch billing {
            case .xSubscriptionUnified: return "Unified X Subscription"
            case .payAsYouGo: return "Pay-as-you-go API"
            case .hybrid: return "Subscription + API Credits"
            case .legacyMonthly: return "Monthly Plan"
            case .subscription:
                if snapshot.status == .stale && snapshot.windows.isEmpty {
                    return "CLI logs detected (no live quota cookie)"
                }
                return nil
            }
        }
        return nil
    }

    @ViewBuilder
    private var localTelemetryOrNoticeView: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let msg = snapshot.message {
                Text(privacyMode ? "Local telemetry hidden in privacy mode." : msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let cost = snapshot.estimatedLocalCostUSD, !privacyMode {
                    Text(String(format: "5h local est: $%.2f", cost))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Cookie") {
                    onConfigure()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    private var expandedDetailsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let source = snapshot.source {
                    Label(source, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let cost = snapshot.estimatedLocalCostUSD, !privacyMode {
                    Text(String(format: "5h CLI est. $%.2f", cost))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let primary = snapshot.primaryWindow,
               let mult = primary.paceDetail?.burnRateMultiplier,
               !privacyMode {
                let elapsedPct = Int((primary.paceDetail?.elapsedPercent ?? 0).rounded())
                Text(String(format: "Burn rate: %.2fx linear pace (%d%% of window elapsed)", mult, elapsedPct))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Open Dashboard") {
                    onReauth()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("Configure") {
                    onConfigure()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var accentColor: Color {
        switch snapshot.status {
        case .ok:
            guard let primary = snapshot.primaryWindow else { return HeadroomTheme.reserve }
            return HeadroomTheme.statusColor(for: primary.paceStatus, headroom: primary.headroomPercent)
        case .stale: return HeadroomTheme.stale
        case .authExpired, .incident: return HeadroomTheme.burningFast
        case .unconfigured: return .secondary
        }
    }
}

public struct SharedPoolCardView: View {
    let pool: SharedPoolGroup
    let privacyMode: Bool
    let showAccountLabel: Bool

    @State private var isHovered = false

    public init(pool: SharedPoolGroup, privacyMode: Bool, showAccountLabel: Bool = false) {
        self.pool = pool
        self.privacyMode = privacyMode
        self.showAccountLabel = showAccountLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(HeadroomTheme.sharedPool.opacity(0.16))
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HeadroomTheme.sharedPool)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(pool.label)
                            .font(.system(size: 13, weight: .semibold))
                        if showAccountLabel {
                            AccountLabelPill(label: pool.accountLabel, privacyMode: privacyMode)
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(pool.memberProviders) { provider in
                            Text(provider.displayName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(HeadroomTheme.sharedPool)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(HeadroomTheme.sharedPool.opacity(0.14), in: Capsule())
                        }
                    }
                }

                Spacer()

                if privacyMode {
                    Text("••% left")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(pool.canonicalWindow.headroomPercent.rounded()))% left")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(
                            HeadroomTheme.statusColor(
                                for: pool.canonicalWindow.paceStatus,
                                headroom: pool.canonicalWindow.headroomPercent
                            )
                        )
                }
            }

            QuotaWindowRow(
                window: pool.canonicalWindow,
                privacyMode: privacyMode,
                showHeaderHero: false
            )

            if !pool.supplementaryWindows.isEmpty {
                Divider()
                    .opacity(0.35)
                VStack(spacing: 8) {
                    ForEach(pool.supplementaryWindows) { sup in
                        QuotaWindowRow(
                            window: sup.window,
                            privacyMode: privacyMode,
                            customLabel: "\(sup.provider.displayName): \(sup.window.label)",
                            showHeaderHero: true
                        )
                    }
                }
            }
        }
        .padding(10.5)
        .background(
            RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous)
                .fill(HeadroomTheme.sharedPool.opacity(isHovered ? 0.085 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(HeadroomTheme.sharedPool.opacity(isHovered ? 0.32 : 0.22), lineWidth: 0.9)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

public struct QuotaWindowRow: View {
    let window: QuotaWindow
    let privacyMode: Bool
    var customLabel: String? = nil
    var showHeaderHero: Bool = true

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(customLabel ?? window.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if privacyMode {
                    Text("Hidden")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text(usageSummaryText)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if showHeaderHero {
                        Text("\(Int(window.headroomPercent.rounded()))% left")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(meterColor)
                    }
                }
            }

            GeometryReader { geo in
                let usedFrac = privacyMode ? 0.42 : min(max(window.usedPercent / 100.0, 0), 1)
                let elapsedFrac = min(max((window.paceDetail?.elapsedPercent ?? 0) / 100.0, 0), 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.primary.opacity(0.09))

                    if usedFrac > 0.005 {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(privacyMode ? Color.secondary.opacity(0.35) : meterColor)
                            .frame(width: max(6, geo.size.width * usedFrac))
                    }

                    if !privacyMode && elapsedFrac > 0.03 && elapsedFrac < 0.98 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: 2, height: 11)
                            .shadow(color: Color.black.opacity(0.35), radius: 1, x: 0, y: 0)
                            .offset(x: geo.size.width * elapsedFrac - 1)
                    }
                }
            }
            .frame(height: 7)

            HStack(spacing: 5) {
                if !privacyMode {
                    Circle()
                        .fill(meterColor)
                        .frame(width: 5.5, height: 5.5)
                    Text(paceCaption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(meterColor)

                    if window.usedPercent < 100.0,
                       let detail = window.paceDetail,
                       detail.willExhaustBeforeReset,
                       let eta = detail.projectedExhaustionAt {
                        Text("· Out in ~\(PaceCalculator.formatCountdown(until: eta))")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(HeadroomTheme.burningFast)
                    }
                } else {
                    Text("Values hidden")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if let resetsAt = window.resetsAt {
                    Text("Resets in \(PaceCalculator.formatCountdown(until: resetsAt))")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var meterColor: Color {
        HeadroomTheme.statusColor(for: window.paceStatus, headroom: window.headroomPercent)
    }

    private var usageSummaryText: String {
        switch window.unit {
        case .percent:
            return String(format: "%.0f%% used", window.usedPercent)
        case .dollars, .requests, .tokens:
            return window.formattedUsage
        }
    }

    private var paceCaption: String {
        if window.usedPercent >= 100.0 {
            return "Limit Reached"
        }
        return window.paceStatus.displayLabel
    }
}

public struct CompactUnconfiguredRow: View {
    let snapshot: ProviderSnapshot
    let showAccountLabel: Bool
    let privacyMode: Bool
    let onConnect: () -> Void

    @State private var isHovered = false

    public init(
        snapshot: ProviderSnapshot,
        showAccountLabel: Bool = false,
        privacyMode: Bool = false,
        onConnect: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.showAccountLabel = showAccountLabel
        self.privacyMode = privacyMode
        self.onConnect = onConnect
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProviderBadgeIcon(provider: snapshot.provider, tint: .secondary)
            Text(snapshot.provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            if showAccountLabel {
                AccountLabelPill(label: snapshot.accountLabel, privacyMode: privacyMode)
            }
            Text("Not connected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Connect") {
                onConnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.055 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
    }
}
