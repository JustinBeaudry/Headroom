import SwiftUI
import HeadroomCore

public struct MenuBarLabelView: View {
    let viewModel: HeadroomViewModel

    public init(viewModel: HeadroomViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let image = MenuBarRenderer.render(
            items: viewModel.menuBarDisplayItems,
            displayMode: viewModel.config.menuBarDisplayMode,
            metricMode: viewModel.config.menuBarMetricMode,
            colorize: viewModel.config.menuBarColorize,
            privacyMode: viewModel.privacyMode,
            forceLightText: false
        )
        Image(nsImage: image)
            .accessibilityLabel("Headroom AI Quotas")
    }
}
