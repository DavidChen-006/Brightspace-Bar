import RepoBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var appModel: AppModel
    let showsCloseButton: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isOwnerFilterFocused: Bool
    @State private var ownerFilterText: String

    init(appModel: AppModel, showsCloseButton: Bool = false) {
        self._appModel = Bindable(wrappedValue: appModel)
        self.showsCloseButton = showsCloseButton
        self._ownerFilterText = State(initialValue: OwnerFilterParser.format(appModel.session.settings.repoList.ownerFilter))
    }

    var body: some View {
        Form {
            Section("Account") {
                switch appModel.session.account {
                case .loggedIn(let user):
                    LabeledContent("Signed in as", value: user.username)
                    Button("Sign out") { Task { await appModel.logout() } }
                        .foregroundStyle(.red)
                case .loggingIn:
                    ProgressView("Signing in…")
                case .loggedOut:
                    Button("Sign in") { Task { await appModel.login() } }
                }
            }

            Section("Host") {
                TextField("Enterprise URL", text: enterpriseHostBinding)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text("Leave empty to use github.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Stepper(value: $appModel.session.settings.repoList.displayLimit, in: 1 ... 20) {
                    Text("Repo count: \(appModel.session.settings.repoList.displayLimit)")
                }
                Picker("Sort", selection: $appModel.session.settings.repoList.menuSortKey) {
                    ForEach(RepositorySortKey.allCases, id: \.self) { sortKey in
                        Text(sortKey.label).tag(sortKey)
                    }
                }
                .pickerStyle(.menu)
                TextField("Owners", text: $ownerFilterText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isOwnerFilterFocused)
                    .onSubmit {
                        applyOwnerFilterText()
                    }
                Text("Comma-separated owners. Empty shows all visible repositories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show forks", isOn: $appModel.session.settings.repoList.showForks)
                Toggle("Show archived", isOn: $appModel.session.settings.repoList.showArchived)
                Toggle("Contribution header", isOn: $appModel.session.settings.appearance.showContributionHeader)
            }

            Section("Refresh") {
                Picker("Interval", selection: $appModel.session.settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.label)
                            .tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Heatmap") {
                Picker("Span", selection: $appModel.session.settings.heatmap.span) {
                    ForEach(HeatmapSpan.allCases, id: \.self) { span in
                        Text(span.label).tag(span)
                    }
                }
                .pickerStyle(.menu)
                Picker("Accent", selection: $appModel.session.settings.appearance.accentTone) {
                    ForEach(AccentTone.allCases, id: \.self) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Activity") {
                Picker("Scope", selection: $appModel.session.settings.appearance.activityScope) {
                    ForEach(GlobalActivityScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Debug") {
                Picker("Logging", selection: $appModel.session.settings.loggingVerbosity) {
                    ForEach(LogVerbosity.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Log to file", isOn: $appModel.session.settings.fileLoggingEnabled)
            }

            Section("Diagnostics") {
                Toggle("Enable diagnostics", isOn: $appModel.session.settings.diagnosticsEnabled)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .navigationTitle("Settings")
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onChange(of: appModel.session.settings) { _, _ in
            appModel.persistSettings()
            appModel.refreshScheduler.configure(interval: appModel.session.settings.refreshInterval.seconds) {
                appModel.requestRefresh()
            }
            Task { await DiagnosticsLogger.shared.setEnabled(appModel.session.settings.diagnosticsEnabled) }
            RepoBarLogging.configure(
                verbosity: appModel.session.settings.loggingVerbosity,
                fileLoggingEnabled: appModel.session.settings.fileLoggingEnabled
            )
            appModel.updateHeatmapRange()
        }
        .onChange(of: appModel.session.settings.repoList) { _, _ in
            appModel.requestRefresh(cancelInFlight: true)
        }
        .onChange(of: isOwnerFilterFocused) { _, isFocused in
            if isFocused == false {
                applyOwnerFilterText()
            }
        }
        .onAppear {
            ownerFilterText = OwnerFilterParser.format(appModel.session.settings.repoList.ownerFilter)
        }
    }

    private var enterpriseHostBinding: Binding<String> {
        Binding(
            get: { appModel.session.settings.enterpriseHost?.absoluteString ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    appModel.session.settings.enterpriseHost = nil
                } else {
                    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
                    if let url = URL(string: normalized) {
                        appModel.session.settings.enterpriseHost = url
                    }
                }
                Task { await appModel.applyHostSettings() }
            }
        )
    }

    private func applyOwnerFilterText() {
        let owners = OwnerFilterParser.parse(ownerFilterText)
        appModel.session.settings.repoList.ownerFilter = owners
        ownerFilterText = OwnerFilterParser.format(owners)
    }
}
