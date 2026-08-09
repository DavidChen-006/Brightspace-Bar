struct RecentIssueLabelOption: Hashable {
    let name: String
    let colorHex: String
    let count: Int
}

enum RecentIssueScope: String, CaseIterable, Hashable {
    case all
    case mine

    var label: String {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        }
    }
}
