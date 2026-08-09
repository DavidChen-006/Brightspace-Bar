public enum ActivityEventType: String, Codable, CaseIterable, Sendable {
    case pullRequest = "PullRequestEvent"
    case pullRequestReview = "PullRequestReviewEvent"
    case pullRequestReviewComment = "PullRequestReviewCommentEvent"
    case pullRequestReviewThread = "PullRequestReviewThreadEvent"
    case issueComment = "IssueCommentEvent"
    case issues = "IssuesEvent"
    case push = "PushEvent"
    case release = "ReleaseEvent"
    case watch = "WatchEvent"
    case fork = "ForkEvent"
    case create = "CreateEvent"
    case delete = "DeleteEvent"
    case member = "MemberEvent"
    case `public` = "PublicEvent"
    case gollum = "GollumEvent"
    case commitComment = "CommitCommentEvent"
    case discussion = "DiscussionEvent"
    case sponsorship = "SponsorshipEvent"

    public static func parse(_ rawValue: String?) -> ActivityEventType? {
        guard let rawValue else { return nil }

        return ActivityEventType(rawValue: rawValue)
    }
}
