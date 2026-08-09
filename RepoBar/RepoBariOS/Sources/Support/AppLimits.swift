import Foundation

enum AppLimits {
    enum GlobalActivity {
        static let limit: Int = 25
        static let previewLimit: Int = 20
    }

    enum GlobalCommits {
        static let limit: Int = 25
        static let previewLimit: Int = 5
    }

    enum RepoActivity {
        static let limit: Int = 25
        static let previewLimit: Int = 5
    }

    enum RecentLists {
        static let limit: Int = 20
        static let previewLimit: Int = 5
    }

    enum RepoCommits {
        static let previewLimit: Int = 5
        static let moreLimit: Int = 25
        static let totalLimit: Int = previewLimit + moreLimit
    }

    enum Autocomplete {
        static let addRepoRecentLimit: Int = 10
    }

    enum Files {
        static let maxPreviewBytes: Int = 120 * 1024
    }
}
