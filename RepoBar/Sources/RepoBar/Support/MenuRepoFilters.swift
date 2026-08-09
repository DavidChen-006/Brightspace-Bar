import RepoBarCore

enum MenuRepoSelection: String, CaseIterable, Hashable {
    case all
    case pinned
    case local
    case work

    var label: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .local: "Local"
        case .work: "Work"
        }
    }

    var onlyWith: RepositoryOnlyWith {
        switch self {
        case .all, .pinned, .local:
            .none
        case .work:
            RepositoryOnlyWith(requireIssues: true, requirePRs: true)
        }
    }

    var isPinnedScope: Bool {
        self == .pinned
    }

    var isLocalScope: Bool {
        self == .local
    }
}
