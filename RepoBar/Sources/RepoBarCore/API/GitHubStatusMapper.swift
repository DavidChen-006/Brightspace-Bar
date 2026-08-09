enum GitHubStatusMapper {
    static func ciStatus(fromStatus status: String?, conclusion: String?) -> CIStatus {
        switch conclusion ?? status {
        case "success": .passing
        case "failure", "cancelled", "timed_out": .failing
        case "in_progress", "queued", "waiting": .pending
        default: .unknown
        }
    }
}
