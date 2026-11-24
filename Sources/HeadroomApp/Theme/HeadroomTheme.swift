import SwiftUI
import HeadroomCore

public enum HeadroomTheme {
    // Restrained semantic palette tuned for both dark & light macOS vibrancy
    public static let reserve = Color(red: 0.06, green: 0.73, blue: 0.51)       // Emerald
    public static let onTrack = Color(red: 0.96, green: 0.62, blue: 0.04)       // Amber
    public static let burningFast = Color(red: 0.94, green: 0.27, blue: 0.27)   // Coral Red
    public static let sharedPool = Color(red: 0.06, green: 0.65, blue: 0.91)    // Electric Cyan-Blue
    public static let stale = Color(red: 0.92, green: 0.56, blue: 0.14)

    public static let cardCornerRadius: CGFloat = 10
    public static let popoverWidth: CGFloat = 384

    public static func statusColor(for pace: PaceStatus, headroom: Double) -> Color {
        if headroom <= 15.0 || pace == .burningFast {
            return burningFast
        } else if headroom <= 35.0 || pace == .onTrack {
            return onTrack
        } else {
            return reserve
        }
    }

    public static func providerSymbol(for provider: ProviderID) -> String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "terminal.fill"
        case .gemini: return "diamond.fill"
        case .grok: return "bolt.fill"
        case .cursor: return "cursorarrow.rays"
        }
    }
}

public struct ToolbarIconButton: View {
    let systemName: String
    let helpText: String
    var isActive: Bool = false
    var isSpinning: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    public init(
        systemName: String,
        helpText: String,
        isActive: Bool = false,
        isSpinning: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.helpText = helpText
        self.isActive = isActive
        self.isSpinning = isSpinning
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if isSpinning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isActive ? HeadroomTheme.sharedPool : (isHovered ? .primary : .secondary))
                }
            }
            .frame(width: 28, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? HeadroomTheme.sharedPool.opacity(0.16)
                            : (isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

public struct ProviderBadgeIcon: View {
    let provider: ProviderID
    let tint: Color

    public init(provider: ProviderID, tint: Color) {
        self.provider = provider
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: HeadroomTheme.providerSymbol(for: provider))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
    }
}

public struct SkeletonCardView: View {
    @State private var pulse = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 90, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 56, height: 14)
            }
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color.primary.opacity(0.08))
                .frame(height: 7)
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 72, height: 9)
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 84, height: 9)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HeadroomTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        )
        .opacity(pulse ? 0.55 : 0.95)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
