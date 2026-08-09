enum RepoVisibility: String, CaseIterable, Identifiable {
    case pinned
    case hidden
    case visible

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .pinned: "Pinned"
        case .hidden: "Hidden"
        case .visible: "Visible"
        }
    }
}
