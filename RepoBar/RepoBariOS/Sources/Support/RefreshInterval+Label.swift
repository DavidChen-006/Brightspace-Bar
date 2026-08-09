import RepoBarCore

extension RefreshInterval {
    var label: String {
        switch self {
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        }
    }
}
