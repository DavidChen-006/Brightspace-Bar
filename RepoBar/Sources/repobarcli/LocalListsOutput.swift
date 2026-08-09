import Foundation
import RepoBarCore

func localBranchesTableLines(
    _ snapshot: LocalGitBranchSnapshot,
    useColor: Bool,
    now: Date = Date()
) -> [String] {
    guard snapshot.branches.isEmpty == false else { return ["No branches."] }

    let nameHeader = "BRANCH"
    let currentHeader = "CURRENT"
    let upstreamHeader = "UPSTREAM"
    let aheadHeader = "AHEAD"
    let behindHeader = "BEHIND"
    let lastHeader = "LAST"
    let authorHeader = "BY"

    let nameValues = snapshot.branches.map(\.name)
    let currentValues = snapshot.branches.map { $0.isCurrent ? "✓" : "" }
    let upstreamValues = snapshot.branches.map { $0.upstream ?? "-" }
    let aheadValues = snapshot.branches.map { $0.aheadCount.map(String.init) ?? "-" }
    let behindValues = snapshot.branches.map { $0.behindCount.map(String.init) ?? "-" }
    let lastValues = snapshot.branches.map { $0.lastCommitDate.map { RelativeFormatter.string(from: $0, relativeTo: now) } ?? "-" }
    let authorValues = snapshot.branches.map { $0.lastCommitAuthor ?? "-" }

    let nameWidth = max(nameHeader.count, nameValues.map(\.count).max() ?? 1)
    let currentWidth = max(currentHeader.count, currentValues.map(\.count).max() ?? 1)
    let upstreamWidth = max(upstreamHeader.count, upstreamValues.map(\.count).max() ?? 1)
    let aheadWidth = max(aheadHeader.count, aheadValues.map(\.count).max() ?? 1)
    let behindWidth = max(behindHeader.count, behindValues.map(\.count).max() ?? 1)
    let lastWidth = max(lastHeader.count, lastValues.map(\.count).max() ?? 1)
    let authorWidth = max(authorHeader.count, authorValues.map(\.count).max() ?? 1)

    let header = [
        padRight(nameHeader, to: nameWidth),
        padRight(currentHeader, to: currentWidth),
        padRight(upstreamHeader, to: upstreamWidth),
        padRight(aheadHeader, to: aheadWidth),
        padRight(behindHeader, to: behindWidth),
        padRight(lastHeader, to: lastWidth),
        padRight(authorHeader, to: authorWidth)
    ].joined(separator: "  ")

    var lines: [String] = []
    if snapshot.isDetachedHead {
        let when = snapshot.detachedCommitDate.map { RelativeFormatter.string(from: $0, relativeTo: now) } ?? "unknown"
        let author = snapshot.detachedCommitAuthor ?? "-"
        lines.append("Detached HEAD (\(when) by \(author))")
    }

    lines.append(useColor ? Ansi.bold.wrap(header) : header)

    for idx in snapshot.branches.indices {
        let parts = [
            padRight(nameValues[idx], to: nameWidth),
            padRight(currentValues[idx], to: currentWidth),
            padRight(upstreamValues[idx], to: upstreamWidth),
            padRight(aheadValues[idx], to: aheadWidth),
            padRight(behindValues[idx], to: behindWidth),
            padRight(lastValues[idx], to: lastWidth),
            padRight(authorValues[idx], to: authorWidth)
        ]
        lines.append(parts.joined(separator: "  "))
    }

    return lines
}

func localWorktreesTableLines(
    _ worktrees: [LocalGitWorktree],
    useColor: Bool,
    now: Date = Date()
) -> [String] {
    guard worktrees.isEmpty == false else { return ["No worktrees."] }

    let pathHeader = "PATH"
    let branchHeader = "BRANCH"
    let currentHeader = "CURRENT"
    let upstreamHeader = "UPSTREAM"
    let aheadHeader = "AHEAD"
    let behindHeader = "BEHIND"
    let dirtyHeader = "DIRTY"
    let lastHeader = "LAST"

    let pathValues = worktrees.map { PathFormatter.displayString($0.path.path) }
    let branchValues = worktrees.map { $0.branch ?? "(detached)" }
    let currentValues = worktrees.map { $0.isCurrent ? "✓" : "" }
    let upstreamValues = worktrees.map { $0.upstream ?? "-" }
    let aheadValues = worktrees.map { $0.aheadCount.map(String.init) ?? "-" }
    let behindValues = worktrees.map { $0.behindCount.map(String.init) ?? "-" }
    let dirtyValues = worktrees.map { $0.dirtyCounts?.summary.isEmpty == false ? $0.dirtyCounts?.summary ?? "-" : "-" }
    let lastValues = worktrees.map { $0.lastCommitDate.map { RelativeFormatter.string(from: $0, relativeTo: now) } ?? "-" }

    let pathWidth = max(pathHeader.count, pathValues.map(\.count).max() ?? 1)
    let branchWidth = max(branchHeader.count, branchValues.map(\.count).max() ?? 1)
    let currentWidth = max(currentHeader.count, currentValues.map(\.count).max() ?? 1)
    let upstreamWidth = max(upstreamHeader.count, upstreamValues.map(\.count).max() ?? 1)
    let aheadWidth = max(aheadHeader.count, aheadValues.map(\.count).max() ?? 1)
    let behindWidth = max(behindHeader.count, behindValues.map(\.count).max() ?? 1)
    let dirtyWidth = max(dirtyHeader.count, dirtyValues.map(\.count).max() ?? 1)
    let lastWidth = max(lastHeader.count, lastValues.map(\.count).max() ?? 1)

    let header = [
        padRight(pathHeader, to: pathWidth),
        padRight(branchHeader, to: branchWidth),
        padRight(currentHeader, to: currentWidth),
        padRight(upstreamHeader, to: upstreamWidth),
        padRight(aheadHeader, to: aheadWidth),
        padRight(behindHeader, to: behindWidth),
        padRight(dirtyHeader, to: dirtyWidth),
        padRight(lastHeader, to: lastWidth)
    ].joined(separator: "  ")

    var lines: [String] = []
    lines.append(useColor ? Ansi.bold.wrap(header) : header)

    for idx in worktrees.indices {
        let parts = [
            padRight(pathValues[idx], to: pathWidth),
            padRight(branchValues[idx], to: branchWidth),
            padRight(currentValues[idx], to: currentWidth),
            padRight(upstreamValues[idx], to: upstreamWidth),
            padRight(aheadValues[idx], to: aheadWidth),
            padRight(behindValues[idx], to: behindWidth),
            padRight(dirtyValues[idx], to: dirtyWidth),
            padRight(lastValues[idx], to: lastWidth)
        ]
        lines.append(parts.joined(separator: "  "))
    }

    return lines
}
