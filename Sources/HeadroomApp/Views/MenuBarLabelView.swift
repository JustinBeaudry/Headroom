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
                Image(systemName: "eye.slash.fill")
                Text("HR")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                Image(systemName: urgent.isAuthExpired ? "exclamationmark.triangle.fill" : iconName(for: urgent.pace))
                    .symbolRenderingMode(.hierarchical)
                if urgent.isAuthExpired {
                    Text("\(urgent.shortCode) !")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                } else {
                    Text("\(urgent.shortCode) \(Int(urgent.headroomPercent.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text("HR")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private var miniBarsLabel: some View {
        let entries = viewModel.miniBarEntries
        if entries.isEmpty {
            Image(systemName: "gauge.with.dots.needle.67percent")
        } else {
            HStack(spacing: 2) {
                ForEach(entries, id: \.id) { entry in
                    MiniBarColumn(headroomPercent: entry.headroomPercent, isError: entry.isError)
                }
            }
            .frame(height: 14)
        }
    }

    private func iconName(for pace: PaceStatus) -> String {
        switch pace {
        case .reserve: return "gauge.with.dots.needle.33percent"
        case .onTrack: return "gauge.with.dots.needle.50percent"
        case .burningFast: return "flame.fill"
        }
    }
}

private struct MiniBarColumn: View {
    let headroomPercent: Double
    let isError: Bool

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(headroomPercent / 100.0, 0.08), 1.0)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.22))
                RoundedRectangle(cornerRadius: 1)
                    .fill(isError ? Color.red : Color.primary)
                    .frame(height: geo.size.height * clamped)
            }
        }
        .frame(width: 4, height: 13)
    }
}
