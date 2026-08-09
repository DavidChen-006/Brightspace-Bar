enum RecentPullRequestScope: String, CaseIterable, Hashable {
    case all
    case mine

    var label: String {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        }
    }
}

enum RecentPullRequestEngagement: String, CaseIterable, Hashable {
    case all
    case commented
    case reviewed

    var label: String {
        switch self {
        case .all: "All"
        case .commented: "Commented"
        case .reviewed: "Reviewed"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .commented: "text.bubble"
        case .reviewed: "checkmark.bubble"
        }
    }
}
