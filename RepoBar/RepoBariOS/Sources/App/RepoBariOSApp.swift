import AppIntents
import SwiftUI

@main
struct RepoBariOSApp: App {
    @State private var appModel = AppModel()

    init() {
        _ = (any AppIntent).self
    }

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
        }
    }
}
