import RepoBarCore
import SwiftUI

struct AddRepoSheet: View {
    @Bindable var appModel: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var results: [Repository] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(results) { repo in
                Button {
                    Task {
                        await appModel.addPinned(repo.fullName)
                        isPresented = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repo.fullName).font(.headline)
                        if let release = repo.latestRelease {
                            Text("Latest: \(release.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Issues: \(repo.stats.openIssues) • Owner: \(repo.owner)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Pin a Repo")
        .searchable(text: $query, prompt: "owner/name")
        .onChange(of: query) { _, _ in
            Task { await search() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { isPresented = false }
            }
        }
        .task { await search() }
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let includeForks = appModel.session.settings.repoList.showForks
            let includeArchived = appModel.session.settings.repoList.showArchived
            let repos = try await appModel.searchRepositories(query: query)
            let filtered = RepositoryFilter.apply(repos, includeForks: includeForks, includeArchived: includeArchived)
            results = filtered
        } catch {
            results = []
        }
    }
}
