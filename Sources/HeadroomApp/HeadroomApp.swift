import SwiftUI
import AppKit

final class HeadroomAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep Headroom as a lightweight menu bar utility with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct HeadroomMenuBarApp: App {
    @NSApplicationDelegateAdaptor(HeadroomAppDelegate.self) private var appDelegate
    @State private var viewModel: HeadroomViewModel

    init() {
        let vm = HeadroomViewModel()
        _viewModel = State(initialValue: vm)
        vm.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabelView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }

        Window("Headroom Update", id: "update-window") {
            UpdateWindowView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}
