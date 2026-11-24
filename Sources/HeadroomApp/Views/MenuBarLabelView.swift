import SwiftUI
import HeadroomCore

public struct MenuBarLabelView: View {
    let viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.privacyMode {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11.5, weight: .medium))
                Text("HR")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
        } else {
            switch viewModel.config.menuBarDisplayMode {
            case .mostUrgent:
                mostUrgentLabel
            case .miniBars:
                miniBarsLabel
            }
        }
    }

    @ViewBuilder
    private var mostUrgentLabel: some View {
        if let urgent = viewModel.mostUrgentItem {
            HStack(spacing: 4) {
                Image(systemName: urgent.isAuthExpired ? "exclamationmark.triangle.fill" : gaugeIcon(for: urgent))
                    .font(.system(size: 11.5, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                if urgent.isAuthExpired {
                    Text("\(urgent.shortCode) Auth")
                        .font(.system(size: 11.5, weight: .semibold))
                } else {
                    Text("\(urgent.shortCode) \(Int(urgent.headroomPercent.rounded()))%")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .medium))
                Text("Headroom")
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private var miniBarsLabel: some View {
        let entries = viewModel.miniBarEntries
        if entries.isEmpty {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .medium))
        } else {
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(entries) { entry in
                    MiniBarColumn(headroomPercent: entry.headroomPercent, isError: entry.isError)
                }
            }
            .frame(height: 14)
        }
    }

    private func gaugeIcon(for item: UrgentMenuItem) -> String {
        if item.headroomPercent <= 10.0 {
            return "gauge.with.dots.needle.100percent"
        }
        switch item.pace {
        case .reserve: return "gauge.with.dots.needle.33percent"
        case .onTrack: return "gauge.with.dots.needle.50percent"
        case .burningFast: return "gauge.with.dots.needle.84percent"
        }
    }
}

private struct MiniBarColumn: View {
    let headroomPercent: Double
    let isError: Bool

    var body: some View {
        let fraction = min(max(headroomPercent / 100.0, 0.12), 1.0)
        VStack(spacing: 1) {
            // Subtle headroom ceiling cap tick
            Rectangle()
                .fill(Color.primary.opacity(0.45))
                .frame(width: 4, height: 1)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.2))
                RoundedRectangle(cornerRadius: 1)
                    .fill(isError ? Color.red : Color.primary)
                    .frame(height: 11 * fraction)
            }
            .frame(width: 4, height: 11)
        }
    }
}
