import SwiftUI
import OllmlxCore

@main
struct OllmlxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // No Dock icon — menubar-only app
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Empty scene — all UI driven by AppDelegate's NSStatusItem + NSPopover
        Settings {
            EmptyView()
        }
    }
}
