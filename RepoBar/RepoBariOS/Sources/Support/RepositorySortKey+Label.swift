import RepoBarCore

extension RepositorySortKey {
    var label: String {
        switch self {
        case .activity: "Activity"
        case .issues: "Issues"
        case .pulls: "Pull Requests"
        case .stars: "Stars"
        case .name: "Name"
        case .event: "Event"
        }
    }
}
