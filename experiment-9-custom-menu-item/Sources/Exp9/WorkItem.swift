import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// What a day CARRIES. The grid's contract is positional (index = day offset)
// and says nothing about names — see NewVertical-3 §3.3, which notes that a
// tooltip needs "richer cells". This is that richer cell, kept local to the
// experiment: one day holds zero or more pieces of work, each with a real
// deep link.
//
// The links are the shapes experiment 7 verified in a browser and the ones
// BrightspaceBar's AssignmentLink / QuizLink build today — copied, not
// imported, because exp 9 is deliberately dependency-free:
//
//     assignment  →  …/d2l/lms/dropbox/user/folder_submit_files.d2l?db&grpid&ou
//     quiz        →  …/d2l/lms/quizzing/user/quiz_summary.d2l?qi&ou
//
// Query order is pinned to Brightspace's own markup (db, grpid, ou), the same
// reasoning AssignmentLink records.
// ─────────────────────────────────────────────────────────────────────────────

/// One assignment / quiz / test due on a given day.
struct WorkItem {
    let kind: Tier
    let title: String
    let url: URL

    /// Human word for the tier, shown right-aligned in the popup row.
    var kindLabel: String {
        switch self.kind {
        case .assignment: "Assignment"
        case .quiz: "Quiz"
        case .test: "Test"
        }
    }
}

enum WorkLink {
    static let base = URL(string: "https://purdue.brightspace.com")!

    /// `{base}/d2l/lms/dropbox/user/folder_submit_files.d2l?db={id}&grpid=0&ou={course}`
    static func assignment(courseId: Int, assignmentId: Int) -> URL {
        Self.build(path: "d2l/lms/dropbox/user/folder_submit_files.d2l", items: [
            URLQueryItem(name: "db", value: String(assignmentId)),
            URLQueryItem(name: "grpid", value: "0"),
            URLQueryItem(name: "ou", value: String(courseId)),
        ])
    }

    /// `{base}/d2l/lms/quizzing/user/quiz_summary.d2l?qi={id}&ou={course}`
    ///
    /// Tests use this shape too: Brightspace has no separate "test" object — a
    /// midterm is a quiz with a scarier name. `Tier.test` is a *display* tier
    /// (it is what paints the cell red), not a second link template.
    static func quiz(courseId: Int, quizId: Int) -> URL {
        Self.build(path: "d2l/lms/quizzing/user/quiz_summary.d2l", items: [
            URLQueryItem(name: "qi", value: String(quizId)),
            URLQueryItem(name: "ou", value: String(courseId)),
        ])
    }

    private static func build(path: String, items: [URLQueryItem]) -> URL {
        let url = Self.base.appending(path: path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = items
        return components?.url ?? url
    }
}
