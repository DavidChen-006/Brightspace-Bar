import AppKit
import RepoBarCore
import SwiftUI

struct GitHubArchiveSettingsSection: View {
    @Binding var settings: GitHubArchiveSettings
    let persist: () -> Void
    @State private var repository = ""
    @State private var statuses: [String: GitHubArchiveSourceStatus] = [:]
    @State private var updatingIDs = Set<String>()
    @State private var updateError: String?

    var body: some View {
        Section {
            Toggle("Use archives when rate limited", isOn: self.fallbackBinding)

            if self.settings.sources.isEmpty {
                Text("No GitHub archives configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.settings.sources) { source in
                    self.row(for: source)
                }
            }

            if let updateError {
                Text(updateError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent("Repo") {
                HStack {
                    TextField("owner/repo, URL, or local path", text: self.$repository)
                        .textFieldStyle(.roundedBorder)

                    Button("Add Repo") {
                        self.addArchive()
                    }
                    .disabled(!self.canAdd)

                    Button("Choose Repo…") {
                        self.chooseDirectory { self.repository = $0 }
                    }
                }
            }
        } header: {
            Text("GitHub Archives")
        } footer: {
            Text("Point RepoBar at a snapshot repository. RepoBar manages the imported database internally and uses it only when GitHub is rate limited.")
        }
        .onAppear {
            self.refreshStatuses()
        }
        .onChange(of: self.settings.sources) {
            self.refreshStatuses()
        }
    }

    private var fallbackBinding: Binding<Bool> {
        Binding(
            get: { self.settings.preferArchiveWhenRateLimited },
            set: { newValue in
                self.settings.preferArchiveWhenRateLimited = newValue
                self.persist()
            }
        )
    }

    private var canAdd: Bool {
        guard let source = GitHubArchiveStore.source(repository: self.repository) else {
            return false
        }

        return self.settings.sources.contains { self.matches($0, source) } == false
    }

    private func row(for source: GitHubArchiveSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(source.name, isOn: self.enabledBinding(for: source.id))
                Spacer()
                Button {
                    self.updateArchive(source)
                } label: {
                    if self.updatingIDs.contains(source.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(self.updatingIDs.contains(source.id))
                .help("Pull and import archive")
                Button {
                    self.settings.sources.removeAll { $0.id == source.id }
                    self.persist()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove archive")
            }

            Text(self.detailLine(for: source))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let status = self.statuses[source.id] {
                Text(self.statusLine(for: status))
                    .font(.caption2)
                    .foregroundStyle(status.readyForRead ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                self.settings.sources.first(where: { $0.id == id })?.enabled ?? false
            },
            set: { newValue in
                guard let index = self.settings.sources.firstIndex(where: { $0.id == id }) else { return }

                self.settings.sources[index].enabled = newValue
                self.persist()
            }
        )
    }

    private func detailLine(for source: GitHubArchiveSource) -> String {
        let repo = source.remoteURL ?? source.localRepositoryPath.map(PathFormatter.displayString) ?? "-"
        return "repo: \(repo)"
    }

    private func statusLine(for status: GitHubArchiveSourceStatus) -> String {
        var parts = [status.readyForRead ? "ready" : "not ready"]
        if let rows = status.importedRowCount {
            parts.append("\(rows) rows")
        }
        if let lastImportAt = status.lastImportAt {
            parts.append("imported \(RelativeFormatter.string(from: lastImportAt, relativeTo: Date()))")
        }
        if status.issues.isEmpty == false {
            parts.append(status.issues.joined(separator: "; "))
        }
        return parts.joined(separator: " · ")
    }

    private func addArchive() {
        guard let source = GitHubArchiveStore.source(repository: self.repository),
              self.settings.sources.contains(where: { self.matches($0, source) }) == false
        else { return }

        self.settings.sources.append(source)
        self.repository = ""
        self.persist()
        self.refreshStatuses()
    }

    private func updateArchive(_ source: GitHubArchiveSource) {
        self.updateError = nil
        self.updatingIDs.insert(source.id)
        Task.detached {
            do {
                let update = try GitHubArchiveStore.update(source: source)
                await MainActor.run {
                    if let index = self.settings.sources.firstIndex(where: { $0.id == source.id }) {
                        self.settings.sources[index] = update.source
                        self.persist()
                    }
                    self.updatingIDs.remove(source.id)
                    self.refreshStatuses()
                }
            } catch {
                await MainActor.run {
                    self.updateError = error.localizedDescription
                    self.updatingIDs.remove(source.id)
                    self.refreshStatuses()
                }
            }
        }
    }

    private func refreshStatuses() {
        let values = (try? GitHubArchiveStore.statuses(settings: self.settings)) ?? []
        self.statuses = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    private func chooseDirectory(_ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            apply(PathFormatter.abbreviateHome(url.resolvingSymlinksInPath().path))
        }
    }

    private func matches(_ existing: GitHubArchiveSource, _ candidate: GitHubArchiveSource) -> Bool {
        GitHubArchiveStore.sameArchiveLocation(existing, candidate)
    }
}
