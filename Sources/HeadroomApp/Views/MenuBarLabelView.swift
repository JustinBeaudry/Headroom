import SwiftUI
import HeadroomCore

public struct MenuBarLabelView: View {
    let viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.privacyMode {
            Label("HR", systemImage: "eye.slash")
                .labelStyle(.titleAndIcon)
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
            if urgent.isAuthExpired {
                Label("\(urgent.menuBarCode) Auth", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Label(
                    "\(urgent.menuBarCode) \(Int(urgent.headroomPercent.rounded()))%",
                    systemImage: gaugeIcon(for: urgent)
                )
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
            }
        } else {
            Label("Headroom", systemImage: "gauge.with.dots.needle.67percent")
                .labelStyle(.titleAndIcon)
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
