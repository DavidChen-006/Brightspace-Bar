import RepoBarCore
import SwiftUI

struct DebugSettingsView: View {
    @Bindable var session: Session
    let appState: AppState
    @State private var diagnostics = DiagnosticsSummary.empty
    @State private var gitExecutableInfo = LocalProjectsService.gitExecutableInfo()

    var body: some View {
        Form {
            Section("Debug") {
                Button("Clear cache") {
                    Task {
                        await self.appState.clearCaches()
                        await self.loadDiagnosticsIfEnabled()
                    }
                }
                Button("Clear repo detail cache") {
                    Task {
                        await self.appState.github.clearRepoDetailCache()
                        await self.loadDiagnosticsIfEnabled()
                    }
                }
                Button("Clear contribution heatmap cache") {
                    self.appState.clearContributionCache()
                }
                Button("Clear release cache") {
                    Task {
                        await self.appState.github.clearCache()
                        self.appState.requestRefresh(cancelInFlight: true)
                    }
                }
                Button("Force refresh") {
                    self.appState.requestRefresh(cancelInFlight: true)
                }
                Toggle("Show diagnostics overlay", isOn: self.$session.settings.diagnosticsEnabled)
                    .onChange(of: self.session.settings.diagnosticsEnabled) { _, newValue in
                        self.appState.persistSettings()
                        Task {
                            await DiagnosticsLogger.shared.setEnabled(newValue)
                            await self.loadDiagnosticsIfEnabled()
                        }
                    }
            }

            Section("Logging") {
                Picker("Verbosity", selection: self.$session.settings.loggingVerbosity) {
                    ForEach(LogVerbosity.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                Toggle("Log to file", isOn: self.$session.settings.fileLoggingEnabled)
            }
            .onChange(of: self.session.settings.loggingVerbosity) { _, _ in
                self.applyLoggingSettings()
            }
            .onChange(of: self.session.settings.fileLoggingEnabled) { _, _ in
                self.applyLoggingSettings()
            }

            Section("Diagnostics") {
                LabeledContent("Git binary") {
                    Text(self.gitExecutableInfo.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Git version") {
                    Text(self.gitExecutableInfo.version ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Git sandboxed") {
                    Text(self.gitExecutableInfo.isSandboxed ? "Yes" : "No")
                }
                if let error = self.gitExecutableInfo.error, !error.isEmpty {
                    LabeledContent("Git error") {
                        Text(error)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("API host") {
                    Text(self.diagnostics.apiHost.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("REST rate limit") {
                    Text(
                        self.diagnostics.restRateLimit.map(self.formatRate)
                            ?? "— (not fetched yet)"
                    )
                }
                LabeledContent("GraphQL rate limit") {
                    Text(
                        self.diagnostics.graphQLRateLimit.map(self.formatRate)
                            ?? "— (not fetched yet)"
                    )
                }
                if let reset = diagnostics.rateLimitReset {
                    LabeledContent("Rate limit resets") {
                        Text(RelativeFormatter.string(from: reset, relativeTo: Date()))
                    }
                }
                if let error = diagnostics.lastRateLimitError {
                    LabeledContent("Last API notice") { Text(error).foregroundStyle(.red) }
                }
                if self.diagnostics.endpointCooldowns.isEmpty == false {
                    LabeledContent("Endpoint cooldowns") {
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(self.diagnostics.endpointCooldowns, id: \.url) { cooldown in
                                Text(self.endpointCooldownText(cooldown))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                LabeledContent("Backoff entries") { Text("\(self.diagnostics.backoffEntries)") }
                LabeledContent("ETag entries") { Text("\(self.diagnostics.etagEntries)") }
                Button("Refresh diagnostics") { Task { await self.loadDiagnosticsIfEnabled() } }
            }
            .opacity(self.session.settings.diagnosticsEnabled ? 1 : 0.4)
            .disabled(!self.session.settings.diagnosticsEnabled)
        }
        .padding()
        .task {
            self.gitExecutableInfo = LocalProjectsService.gitExecutableInfo()
            await self.loadDiagnosticsIfEnabled()
        }
    }

    private func loadDiagnosticsIfEnabled() async {
        guard self.session.settings.diagnosticsEnabled else {
            self.diagnostics = .empty
            return
        }

        self.diagnostics = await self.appState.diagnostics()
    }

    private func applyLoggingSettings() {
        self.appState.persistSettings()
        RepoBarLogging.configure(
            verbosity: self.session.settings.loggingVerbosity,
            fileLoggingEnabled: self.session.settings.fileLoggingEnabled
        )
    }

    private func formatRate(_ snapshot: RateLimitSnapshot) -> String {
        var parts: [String] = []
        if let resource = snapshot.resource?.uppercased() {
            parts.append(resource)
        }
        if let remaining = snapshot.remaining, let limit = snapshot.limit {
            parts.append("\(remaining)/\(limit) left")
        } else if let remaining = snapshot.remaining {
            parts.append("\(remaining) remaining")
        } else if let limit = snapshot.limit {
            parts.append("limit \(limit)")
        }
        if let used = snapshot.used {
            parts.append("\(used) used")
        }
        if let reset = snapshot.reset {
            parts.append("resets \(RelativeFormatter.string(from: reset, relativeTo: Date()))")
        }
        let text = parts.joined(separator: " • ")
        return text.isEmpty ? "—" : text
    }

    private func endpointCooldownText(_ cooldown: EndpointCooldownSummary) -> String {
        let label = if let repository = cooldown.repository {
            "\(repository) \(cooldown.endpoint)"
        } else {
            cooldown.endpoint
        }
        return "\(label), retry \(RelativeFormatter.string(from: cooldown.retryAfter, relativeTo: Date()))"
    }
}
