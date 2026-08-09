import AppKit

@MainActor
enum AppActions {
    static func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
