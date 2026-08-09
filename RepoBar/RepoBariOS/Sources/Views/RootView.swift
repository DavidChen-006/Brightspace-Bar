import RepoBarCore
import SwiftUI

struct RootView: View {
    @Bindable var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .repos

    var body: some View {
        ZStack {
            GlassBackground()
            content
        }
        .onOpenURL { url in
            if appModel.handleIncomingURL(url) {
                selectedTab = .status
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appModel.requestRefresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.session.account {
        case .loggedOut, .loggingIn:
            LoginView(appModel: appModel)
        case .loggedIn:
            TabView(selection: $selectedTab) {
                NavigationStack {
                    RepoListView(appModel: appModel)
                }
                .tabItem { Label("Repos", systemImage: "square.grid.2x2") }
                .tag(AppTab.repos)

                NavigationStack {
                    ActivityView(appModel: appModel)
                }
                .tabItem { Label("Activity", systemImage: "bolt.heart") }
                .tag(AppTab.activity)

                NavigationStack {
                    StatusView(appModel: appModel)
                }
                .tabItem { Label("Status", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(AppTab.status)

                NavigationStack {
                    SettingsView(appModel: appModel)
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
            }
        }
    }
}
