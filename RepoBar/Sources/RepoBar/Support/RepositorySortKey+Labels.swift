import RepoBarCore

extension RepositorySortKey {
    static var menuCases: [RepositorySortKey] {
        [.activity, .issues, .pulls, .stars, .name]
    }

    static var settingsCases: [RepositorySortKey] {
        [.activity, .issues, .pulls, .stars, .name]
    }

    var menuLabel: String {
        switch self {
        case .activity: "Activity"
        case .issues: "Issues"
        case .pulls: "PRs"
        case .stars: "Stars"
        case .name: "Name"
        case .event: "Event"
        }
    }

    var settingsLabel: String {
        switch self {
        case .activity: "Latest activity"
        case .issues: "Most issues"
        case .pulls: "Most PRs"
        case .stars: "Most stars"
        case .name: "Repository name"
        case .event: "Latest event"
        }
    }

    var menuSymbolName: String {
        switch self {
        case .activity: "clock"
        case .issues: "exclamationmark.circle"
        case .pulls: "arrow.triangle.branch"
        case .stars: "star"
        case .name: "textformat"
        case .event: "bolt.horizontal"
        }
    }
}
