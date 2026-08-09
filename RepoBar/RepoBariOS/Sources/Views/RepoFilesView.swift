import RepoBarCore
import SwiftUI

struct RepoFilesView: View {
    @Bindable var appModel: AppModel
    let repository: Repository

    var body: some View {
        RepoFileListView(appModel: appModel, repository: repository, path: nil)
            .navigationDestination(for: RepoFileDestination.self) { destination in
                switch destination {
                case .directory(let path):
                    RepoFileListView(appModel: appModel, repository: repository, path: path)
                case .file(let item):
                    RepoFilePreviewView(appModel: appModel, repository: repository, item: item)
                }
            }
    }
}

enum RepoFileDestination: Hashable {
    case directory(String)
    case file(RepoContentItem)
}

private struct RepoFileListView: View {
    @Bindable var appModel: AppModel
    let repository: Repository
    let path: String?
    private let logger = RepoBarLogging.logger("repo-files")
    @State private var items: [RepoContentItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error)
                    .foregroundStyle(.orange)
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                if item.isDirectory {
                    NavigationLink(value: RepoFileDestination.directory(item.path)) {
                        Label(item.name, systemImage: "folder")
                    }
                } else {
                    NavigationLink(value: RepoFileDestination.file(item)) {
                        Label(item.name, systemImage: "doc.text")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .navigationTitle(title)
        .task { await load() }
    }

    private var title: String {
        guard let path, path.isEmpty == false else { return "Files" }
        return path.split(separator: "/").last.map(String.init) ?? "Files"
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let contents = try await appModel.github.repoContents(owner: repository.owner, name: repository.name, path: path)
            let sorted = contents.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            items = sorted
            error = nil
        } catch {
            logger.warning("Repo files list failed for \(repository.fullName) path=\(path ?? "/"): \(String(describing: error))")
            items = []
            let location = path?.isEmpty == false ? path ?? "" : "repository root"
            self.error = "Unable to load files for \(location). \(error.userFacingMessage)"
        }
    }
}

private struct RepoFilePreviewView: View {
    @Bindable var appModel: AppModel
    let repository: Repository
    let item: RepoContentItem
    private let logger = RepoBarLogging.logger("repo-files")
    @State private var content: String?
    @State private var isLoading = false
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading…")
            } else if let content {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            } else {
                Text(error ?? "Preview not available")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .background(GlassBackground())
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let url = item.htmlURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let size = item.size, size > AppLimits.Files.maxPreviewBytes {
                error = "File too large to preview"
                return
            }
            let data = try await appModel.github.repoFileContents(owner: repository.owner, name: repository.name, path: item.path)
            if let text = String(data: data, encoding: .utf8) {
                content = text
                error = nil
            } else {
                error = "Binary file preview not supported"
            }
        } catch {
            logger.warning("Repo file preview failed for \(repository.fullName) file=\(item.path): \(String(describing: error))")
            self.error = "Unable to load preview. \(error.userFacingMessage)"
        }
    }
}
