import Foundation
import RepoBarCore

struct RecentItemsRow {
    let updatedLabel: String
    let numberLabel: String
    let authorLabel: String
    let titleLabel: String
    let url: URL
}

func issuesTableLines(
    _ issues: [RepoIssueSummary],
    useColor: Bool,
    includeURL: Bool,
    now: Date = Date()
) -> [String] {
    guard issues.isEmpty == false else { return ["No open issues."] }

    let rows = issues.map { issue in
        RecentItemsRow(
            updatedLabel: RelativeFormatter.string(from: issue.updatedAt, relativeTo: now),
            numberLabel: "#\(issue.number)",
            authorLabel: issue.authorLogin.map { "@\($0)" } ?? "-",
            titleLabel: truncate(issue.title.singleLine, max: 100),
            url: issue.url
        )
    }

    return recentItemsTableLines(
        rows,
        useColor: useColor,
        includeURL: includeURL,
        numberColor: Ansi.red,
        includesDraftColumn: false
    )
}

func pullsTableLines(
    _ pulls: [RepoPullRequestSummary],
    useColor: Bool,
    includeURL: Bool,
    now: Date = Date()
) -> [String] {
    guard pulls.isEmpty == false else { return ["No open pull requests."] }

    let rows = pulls.map { pr in
        RecentItemsRow(
            updatedLabel: RelativeFormatter.string(from: pr.updatedAt, relativeTo: now),
            numberLabel: "#\(pr.number)",
            authorLabel: pr.authorLogin.map { "@\($0)" } ?? "-",
            titleLabel: truncate(pr.title.singleLine, max: 100),
            url: pr.url
        )
    }

    return recentItemsTableLines(
        rows,
        useColor: useColor,
        includeURL: includeURL,
        numberColor: Ansi.magenta,
        includesDraftColumn: true,
        isDraft: { index in pulls[index].isDraft }
    )
}

private func recentItemsTableLines(
    _ rows: [RecentItemsRow],
    useColor: Bool,
    includeURL: Bool,
    numberColor: Ansi.Code,
    includesDraftColumn: Bool,
    isDraft: ((Int) -> Bool)? = nil
) -> [String] {
    let updatedHeader = "UPDATED"
    let numberHeader = "#"
    let authorHeader = "BY"
    let titleHeader = "TITLE"
    let urlHeader = "URL"

    let updatedWidth = max(updatedHeader.count, rows.map(\.updatedLabel.count).max() ?? 1)
    let numberWidth = max(numberHeader.count, rows.map(\.numberLabel.count).max() ?? 1)
    let authorWidth = max(authorHeader.count, min(24, rows.map(\.authorLabel.count).max() ?? 1))

    var headerParts: [String] = []
    if includesDraftColumn {
        headerParts.append("D")
    }
    headerParts.append(padRight(updatedHeader, to: updatedWidth))
    headerParts.append(padRight(numberHeader, to: numberWidth))
    headerParts.append(padRight(authorHeader, to: authorWidth))
    headerParts.append(titleHeader)
    if includeURL, !Ansi.supportsLinks {
        headerParts.append(urlHeader)
    }
    let header = headerParts.joined(separator: "  ")

    var lines: [String] = []
    lines.append(useColor ? Ansi.bold.wrap(header) : header)

    for (index, row) in rows.enumerated() {
        var parts: [String] = []
        if includesDraftColumn {
            let d = (isDraft?(index) == true) ? "D" : " "
            parts.append(useColor && d == "D" ? Ansi.yellow.wrap(d) : d)
        }

        let updated = padRight(row.updatedLabel, to: updatedWidth)
        let number = padRight(row.numberLabel, to: numberWidth)
        let author = padRight(truncate(row.authorLabel, max: authorWidth), to: authorWidth)

        let coloredUpdated = useColor ? Ansi.gray.wrap(updated) : updated
        let coloredNumber = useColor ? numberColor.wrap(number) : number
        let coloredAuthor = useColor ? Ansi.gray.wrap(author) : author

        parts.append(coloredUpdated)
        parts.append(coloredNumber)
        parts.append(coloredAuthor)

        let title: String = if includeURL, Ansi.supportsLinks {
            Ansi.link(row.titleLabel, url: row.url, enabled: true)
        } else {
            row.titleLabel
        }
        parts.append(title)

        if includeURL, !Ansi.supportsLinks {
            parts.append(row.url.absoluteString)
        }

        lines.append(parts.joined(separator: "  "))
    }

    return lines
}

private func truncate(_ text: String, max: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > max else { return trimmed }

    return String(trimmed.prefix(max)) + "…"
}
