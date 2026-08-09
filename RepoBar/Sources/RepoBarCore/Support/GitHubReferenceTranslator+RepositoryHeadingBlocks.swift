import Foundation

struct RepositoryHeadingListBlockParse {
    let entries: [RepositoryHeadingListBlockEntry]
    let consumedLineIndexes: Set<Int>
    let remainingText: String
    let repositoryFullNames: [String]

    var queries: [GitHubReferenceQuery] {
        self.entries.flatMap(\.queries)
    }
}

struct RepositoryHeadingListBlockEntry {
    let lineIndex: Int
    let queries: [GitHubReferenceQuery]
}

extension GitHubReferenceTranslator {
    static func repositoryHeadingListBlockParse(
        in text: String,
        minimumBareDigits: Int
    ) -> RepositoryHeadingListBlockParse {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [RepositoryHeadingListBlockEntry] = []
        var consumedLineIndexes: Set<Int> = []
        var repositoryFullNames: [String] = []
        var currentRepositoryFullName: String?
        var currentHeadingIndent: Int?
        var currentChildHadIssueReferenceContext = false
        var currentChildHadCommitContext = false
        var pendingRepositoryFullName: String?
        var pendingHeadingIndent: Int?
        var pendingLineIndex: Int?

        for (lineIndex, line) in lines.enumerated() {
            let indent = self.leadingWhitespaceCount(in: line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let listItemBody = self.listItemBody(in: line)
            if let repositoryFullName = self.repositoryHeading(in: listItemBody ?? trimmed) {
                pendingRepositoryFullName = nil
                pendingHeadingIndent = nil
                pendingLineIndex = nil
                currentRepositoryFullName = repositoryFullName
                currentHeadingIndent = indent
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                consumedLineIndexes.insert(lineIndex)
                repositoryFullNames.append(repositoryFullName)
                continue
            }

            if let pendingFullName = pendingRepositoryFullName {
                let pendingIndent = pendingHeadingIndent ?? indent
                let pendingIndex = pendingLineIndex ?? lineIndex
                if trimmed.isEmpty || indent <= pendingIndent {
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                } else if self.isRepositoryHeadingSummary(listItemBody ?? trimmed) {
                    currentRepositoryFullName = pendingFullName
                    currentHeadingIndent = pendingIndent
                    currentChildHadIssueReferenceContext = false
                    currentChildHadCommitContext = false
                    consumedLineIndexes.insert(pendingIndex)
                    consumedLineIndexes.insert(lineIndex)
                    repositoryFullNames.append(pendingFullName)
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                    continue
                } else {
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                }
            }

            let canStartRepositoryOnlyHeading = currentHeadingIndent.map { indent <= $0 } ?? true
            let repositoryOnlyHeading = self.repositoryOnlyHeading(in: listItemBody ?? trimmed)
            if canStartRepositoryOnlyHeading, let repositoryFullName = repositoryOnlyHeading {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                pendingRepositoryFullName = repositoryFullName
                pendingHeadingIndent = indent
                pendingLineIndex = lineIndex
                continue
            }

            if let body = listItemBody {
                if let repositoryFullName = currentRepositoryFullName {
                    if let headingIndent = currentHeadingIndent, indent > headingIndent {
                        let lineQueries = self.leadingRepositoryHeadingQueries(
                            in: body,
                            repositoryFullName: repositoryFullName,
                            minimumBareDigits: minimumBareDigits,
                            previousHadCommitContext: currentChildHadCommitContext,
                            previousHadIssueReferenceContext: currentChildHadIssueReferenceContext
                        )
                        currentChildHadIssueReferenceContext = self.headingChildHasIssueReferenceContext(body)
                        currentChildHadCommitContext = self.headingChildHasCommitContext(body)
                        consumedLineIndexes.insert(lineIndex)
                        if lineQueries.isEmpty == false {
                            entries.append(RepositoryHeadingListBlockEntry(
                                lineIndex: lineIndex,
                                queries: lineQueries
                            ))
                        }
                        continue
                    }
                }

                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }

            guard let repositoryFullName = currentRepositoryFullName,
                  let headingIndent = currentHeadingIndent
            else { continue }

            if trimmed.isEmpty {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }
            guard indent > headingIndent else {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }

            let lineQueries = self.leadingRepositoryHeadingQueries(
                in: trimmed,
                repositoryFullName: repositoryFullName,
                minimumBareDigits: minimumBareDigits,
                previousHadCommitContext: currentChildHadCommitContext,
                previousHadIssueReferenceContext: currentChildHadIssueReferenceContext
            )
            currentChildHadIssueReferenceContext = self.headingChildHasIssueReferenceContext(trimmed)
            currentChildHadCommitContext = self.headingChildHasCommitContext(trimmed)
            consumedLineIndexes.insert(lineIndex)
            if lineQueries.isEmpty == false {
                entries.append(RepositoryHeadingListBlockEntry(
                    lineIndex: lineIndex,
                    queries: lineQueries
                ))
            }
        }

        let remainingText = lines.enumerated()
            .map { consumedLineIndexes.contains($0.offset) ? "" : $0.element }
            .joined(separator: "\n")
        return RepositoryHeadingListBlockParse(
            entries: entries,
            consumedLineIndexes: consumedLineIndexes,
            remainingText: remainingText,
            repositoryFullNames: repositoryFullNames
        )
    }

    static func queriesMergingRepositoryHeadingListBlocks(
        in text: String,
        minimumBareDigits: Int,
        repositoryContextOverride: String?,
        repositoryHeadingListBlockParse: RepositoryHeadingListBlockParse
    ) -> [GitHubReferenceQuery] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entriesByLine = Dictionary(grouping: repositoryHeadingListBlockParse.entries, by: \.lineIndex)
        let allowedNormalDedupeKeys = self.primaryURLShortcutDedupeKeys(
            in: repositoryHeadingListBlockParse.remainingText,
            repositoryContextOverride: repositoryContextOverride
        )
        let normalRepositoryContext = self.normalRepositoryContext(
            in: repositoryHeadingListBlockParse.remainingText,
            repositoryContextOverride: repositoryContextOverride,
            consumedRepositoryFullNames: repositoryHeadingListBlockParse.repositoryFullNames
        )
        var normalLines: [String] = []
        var queries: [GitHubReferenceQuery] = []
        var seen: Set<String> = []

        func append(_ query: GitHubReferenceQuery) {
            guard seen.insert(repositoryHeadingDedupeKey(for: query)).inserted else { return }

            queries.append(query)
        }

        func flushNormalLines() {
            guard normalLines.isEmpty == false else { return }

            let chunkText = normalLines.joined(separator: "\n")
            let localQueries = self.normalQueries(
                from: chunkText,
                minimumBareDigits: minimumBareDigits,
                repositoryContextOverride: normalRepositoryContext
            ) + self.chunkPrimaryCompoundListQueries(
                in: chunkText,
                repositoryContext: normalRepositoryContext
            )
            let localScopedIssueNumbers = Set<Int>(localQueries.compactMap { query in
                guard case let .repositoryIssueNumber(_, number) = query else { return nil }

                return number
            })
            let localPrimaryURLShortcutScopedKeys = self.localPrimaryURLShortcutScopedKeys(
                in: chunkText,
                allowedNormalDedupeKeys: allowedNormalDedupeKeys
            )
            for query in localQueries {
                let queryIsAllowed = self.normalQueryIsAllowedByPrimaryURLShortcut(
                    query,
                    allowedNormalDedupeKeys: allowedNormalDedupeKeys,
                    localPrimaryURLShortcutScopedKeys: localPrimaryURLShortcutScopedKeys,
                    localScopedIssueNumbers: localScopedIssueNumbers
                )
                if queryIsAllowed == false {
                    continue
                }
                append(query)
            }
            normalLines.removeAll(keepingCapacity: true)
        }

        for lineIndex in lines.indices {
            if repositoryHeadingListBlockParse.consumedLineIndexes.contains(lineIndex) {
                flushNormalLines()
                for entry in entriesByLine[lineIndex] ?? [] {
                    for query in entry.queries {
                        append(query)
                    }
                }
                continue
            }

            normalLines.append(lines[lineIndex])
        }
        flushNormalLines()

        return queries
    }

    private static func chunkPrimaryCompoundListQueries(
        in text: String,
        repositoryContext: String?
    ) -> [GitHubReferenceQuery] {
        var queries: [GitHubReferenceQuery] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let body = self.listItemBody(in: line),
                  let firstToken = self.referenceTokens(in: body).first
            else { continue }

            let bareSeriesQueries = self.compoundBareIssueQueries(from: firstToken)
            if bareSeriesQueries.isEmpty == false {
                queries.append(contentsOf: bareSeriesQueries.map {
                    self.applyingRepositoryContext(repositoryContext, to: $0)
                })
            }
        }
        return self.dedupedQueries(queries)
    }

    private static func normalRepositoryContext(
        in remainingText: String,
        repositoryContextOverride: String?,
        consumedRepositoryFullNames: [String]
    ) -> String? {
        guard repositoryContextOverride == nil else { return repositoryContextOverride }

        if let context = self.repositoryContext(in: self.droppingRepositoryOnlyListItems(from: remainingText)) {
            return context
        }

        guard let context = self.listItemRepositoryContext(in: remainingText) else { return nil }

        let loweredContext = context.lowercased()
        let hasDifferentConsumedRepository = consumedRepositoryFullNames.contains {
            $0.lowercased() != loweredContext
        }
        return hasDifferentConsumedRepository ? nil : context
    }

    private static func droppingRepositoryOnlyListItems(from text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let line = String(line)
                let listItemIsRepositoryOnly = self.listItemBody(in: line).map {
                    self.repositoryOnlyHeading(in: $0) != nil
                } ?? false
                if listItemIsRepositoryOnly {
                    return ""
                }
                if self.repositoryOnlyHeading(in: line) != nil {
                    return ""
                }

                return line
            }
            .joined(separator: "\n")
    }

    private static func normalQueryIsAllowedByPrimaryURLShortcut(
        _ query: GitHubReferenceQuery,
        allowedNormalDedupeKeys: Set<String>?,
        localPrimaryURLShortcutScopedKeys: Set<String>,
        localScopedIssueNumbers: Set<Int>
    ) -> Bool {
        guard let allowedNormalDedupeKeys else { return true }

        if case let .issueNumber(number) = query {
            if allowedNormalDedupeKeys.contains("issue:\(number)"), localScopedIssueNumbers.contains(number) {
                return false
            }
        }
        if allowedNormalDedupeKeys.contains(repositoryHeadingDedupeKey(for: query)) {
            return true
        }
        if case .repositoryIssueNumber = query {
            return localPrimaryURLShortcutScopedKeys.contains(repositoryHeadingDedupeKey(for: query))
        }
        return false
    }

    private static func localPrimaryURLShortcutScopedKeys(
        in text: String,
        allowedNormalDedupeKeys: Set<String>?
    ) -> Set<String> {
        guard let allowedNormalDedupeKeys else { return [] }

        var keys: Set<String> = []
        var currentPrimaryNumbers: Set<Int> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let body = self.listItemBody(in: line) {
                currentPrimaryNumbers = self.primaryListBodyShortcutIssueNumbers(
                    in: body,
                    allowedNormalDedupeKeys: allowedNormalDedupeKeys
                )
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentPrimaryNumbers = []
            }

            guard currentPrimaryNumbers.isEmpty == false else { continue }

            for token in self.referenceTokens(in: line) {
                guard let query = self.urlQuery(from: token),
                      case let .repositoryIssueNumber(_, number) = query,
                      currentPrimaryNumbers.contains(number)
                else { continue }

                keys.insert(repositoryHeadingDedupeKey(for: query))
            }
        }
        return keys
    }

    private static func primaryListBodyShortcutIssueNumbers(
        in body: String,
        allowedNormalDedupeKeys: Set<String>
    ) -> Set<Int> {
        guard let firstToken = self.referenceTokens(in: body).first else { return [] }

        let queries = self.compoundBareIssueQueries(from: firstToken) + [
            self.tokenQuery(
                from: firstToken,
                minimumBareDigits: 1,
                allowBareIssueNumber: false,
                allowNumericCommitHash: false
            )
        ].compactMap(\.self)
        return Set(queries.compactMap { query in
            guard case let .issueNumber(number) = query,
                  allowedNormalDedupeKeys.contains("issue:\(number)")
            else { return nil }

            return number
        })
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix(while: \.isWhitespace).count
    }

    private static func repositoryHeading(in listItemBody: String) -> String? {
        guard let colon = listItemBody.firstIndex(of: ":") else { return nil }

        let suffix = String(listItemBody[listItemBody.index(after: colon)...])
        guard self.isRepositoryHeadingSummary(suffix) else { return nil }

        let suffixTokens = self.referenceTokens(in: suffix)
        guard suffixTokens.contains(where: {
            self.issueNumber(from: $0, minimumBareDigits: 1, allowBareNumber: false) != nil
        }) == false else { return nil }

        let prefixTokens = self.referenceTokens(in: String(listItemBody[..<colon]))
        guard prefixTokens.count == 1,
              let repositoryFullName = prefixTokens.first,
              self.isRepositoryFullName(repositoryFullName)
        else { return nil }

        return repositoryFullName
    }

    private static func repositoryOnlyHeading(in listItemBody: String) -> String? {
        let trimmed = listItemBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(":") == false else { return nil }

        let tokens = self.referenceTokens(in: trimmed)
        guard tokens.count == 1,
              let repositoryFullName = tokens.first,
              self.isRepositoryFullName(repositoryFullName)
        else { return nil }

        return repositoryFullName
    }

    private static func isRepositoryHeadingSummary(_ text: String) -> Bool {
        let tokens = self.referenceTokens(in: text.lowercased())
        guard tokens.isEmpty == false else { return false }

        var hasIssueCount = false
        var hasPullRequestCount = false
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "/" {
                index = tokens.index(after: index)
                continue
            }

            guard Int(token) != nil else { return false }

            index = tokens.index(after: index)
            guard index < tokens.endIndex else { return false }

            let noun = tokens[index]
            if noun == "issue" || noun == "issues" {
                hasIssueCount = true
                index = tokens.index(after: index)
                continue
            }
            if noun == "pr" || noun == "prs" {
                hasPullRequestCount = true
                index = tokens.index(after: index)
                continue
            }
            if self.startsPullRequestPhrase(tokens: tokens, index: index) {
                hasPullRequestCount = true
                index = tokens.index(index, offsetBy: 2)
                continue
            }
            return false
        }

        return hasIssueCount && hasPullRequestCount
    }

    private static func startsPullRequestPhrase(tokens: [String], index: Array<String>.Index) -> Bool {
        self.tokenIsPull(tokens: tokens, index: index) &&
            tokens.indices.contains(tokens.index(after: index)) &&
            ["request", "requests"].contains(tokens[tokens.index(after: index)])
    }

    private static func tokenIsPull(tokens: [String], index: Array<String>.Index) -> Bool {
        tokens[index] == "pull"
    }

    private static func leadingRepositoryHeadingQueries(
        in line: String,
        repositoryFullName: String,
        minimumBareDigits: Int,
        previousHadCommitContext: Bool,
        previousHadIssueReferenceContext: Bool
    ) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: line)
        let allowsCommitHash = previousHadCommitContext || self.headingChildHasCommitContext(line)
        let allowsContextualBareIssueNumber = self.isIssueCountSummary(line) == false
        let explicitLineQueries = self.explicitRepositoryHeadingLineQueries(
            in: line,
            minimumBareDigits: minimumBareDigits
        )
        let explicitLineNumbers = Set(explicitLineQueries.compactMap(\.repositoryIssueNumber))
        let tokenOptions = RepositoryHeadingTokenOptions(
            repositoryFullName: repositoryFullName,
            allowsCommitHash: allowsCommitHash,
            allowsContextualBareIssueNumber: allowsContextualBareIssueNumber,
            explicitLineNumbers: explicitLineNumbers,
            firstExplicitRepositoryIndex: tokens.firstIndex(where: self.isExplicitRepositoryToken),
            minimumBareDigits: minimumBareDigits
        )
        let tokenQueries = tokens.indices.flatMap { index in
            self.repositoryHeadingTokenQueries(
                tokens: tokens,
                index: index,
                options: tokenOptions
            )
        }
        let explicitTokenNumbers = Set<Int>(tokenQueries.compactMap { query in
            guard case let .repositoryIssueNumber(tokenRepositoryFullName, number) = query,
                  tokenRepositoryFullName != repositoryFullName
            else { return nil }

            return number
        })
        let headingTokenNumbers = Set<Int>(tokenQueries.compactMap { query in
            guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                  parentRepositoryFullName == repositoryFullName
            else { return nil }

            return number
        })
        let suppression = RepositoryHeadingSuppression(
            explicitLineNumbers: explicitLineNumbers.union(explicitTokenNumbers),
            headingTokenNumbers: headingTokenNumbers
        )
        let contextualQueries = self.contextualBareIssueQueries(
            in: line,
            minimumBareDigits: minimumBareDigits
        )
        .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
        .filter { query in
            guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                  parentRepositoryFullName == repositoryFullName
            else { return true }

            return suppression.allowsHeadingRepositoryIssueNumber(number)
        }
        let backReferenceQueries = self.repositoryHeadingBackReferenceQueries(
            in: line,
            repositoryFullName: repositoryFullName,
            minimumBareDigits: minimumBareDigits,
            previousHadIssueReferenceContext: previousHadIssueReferenceContext,
            suppression: suppression
        )
        return self.dedupedQueries(tokenQueries + explicitLineQueries + contextualQueries + backReferenceQueries)
    }

    private static func repositoryHeadingTokenQueries(
        tokens: [String],
        index: Array<String>.Index,
        options: RepositoryHeadingTokenOptions
    ) -> [GitHubReferenceQuery] {
        let token = tokens[index]
        let hasPreviousIssueContext = self.previousTokenHasIssueReferenceContext(tokens: tokens, index: index)
        if let explicitRepositoryFullName = self.explicitRepositoryFullName(beforeIssueTokenAt: index, in: tokens) {
            if let number = self.issueNumber(
                from: token,
                minimumBareDigits: options.minimumBareDigits,
                allowBareNumber: hasPreviousIssueContext
            ) {
                return [.repositoryIssueNumber(repositoryFullName: explicitRepositoryFullName, number: number)]
            }
        }
        if options.allowsContextualBareIssueNumber, hasPreviousIssueContext {
            if let number = self.issueNumber(
                from: token,
                minimumBareDigits: options.minimumBareDigits,
                allowBareNumber: true
            ) {
                return [.repositoryIssueNumber(repositoryFullName: options.repositoryFullName, number: number)]
            }
        }
        let isAfterExplicitRepository = options.firstExplicitRepositoryIndex.map { index > $0 } ?? false
        if isAfterExplicitRepository, hasPreviousIssueContext == false {
            let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false)
            if let number, options.explicitLineNumbers.contains(number) {
                return []
            }
        }

        return self.repositoryHeadingTokenQueries(
            token,
            repositoryFullName: options.repositoryFullName,
            allowsCommitHash: options.allowsCommitHash
        )
    }

    private static func explicitRepositoryFullName(
        beforeIssueTokenAt index: Array<String>.Index,
        in tokens: [String]
    ) -> String? {
        guard index > tokens.startIndex else { return nil }

        let previousIndex = tokens.index(before: index)
        if self.isRepositoryFullName(tokens[previousIndex]) {
            return tokens[previousIndex]
        }
        if let repositoryFullName = self.explicitRepositoryFullNameBeforePullRequestPhrase(
            previousIndex: previousIndex,
            in: tokens
        ) {
            return repositoryFullName
        }

        guard index > tokens.index(after: tokens.startIndex),
              ["pr", "prs", "issue", "issues"].contains(tokens[previousIndex].lowercased())
        else { return nil }

        let repositoryIndex = tokens.index(before: previousIndex)
        guard self.isRepositoryFullName(tokens[repositoryIndex]) else { return nil }

        return tokens[repositoryIndex]
    }

    private static func isExplicitRepositoryToken(_ token: String) -> Bool {
        self.isRepositoryFullName(token) || self.repositoryIssueQuery(from: token) != nil
    }

    private static func explicitRepositoryFullNameBeforePullRequestPhrase(
        previousIndex: Array<String>.Index,
        in tokens: [String]
    ) -> String? {
        let previousToken = tokens[previousIndex].lowercased()
        guard previousToken == "request" || previousToken == "requests",
              previousIndex > tokens.index(after: tokens.startIndex)
        else { return nil }

        let pullIndex = tokens.index(before: previousIndex)
        guard tokens[pullIndex].lowercased() == "pull",
              pullIndex > tokens.startIndex
        else { return nil }

        let repositoryIndex = tokens.index(before: pullIndex)
        guard self.isRepositoryFullName(tokens[repositoryIndex]) else { return nil }

        return tokens[repositoryIndex]
    }

    private static func previousTokenHasIssueReferenceContext(tokens: [String], index: Array<String>.Index) -> Bool {
        guard index > tokens.startIndex else { return false }

        let previousIndex = tokens.index(before: index)
        let previousToken = tokens[previousIndex].lowercased()
        if ["pr", "prs", "issue", "issues"].contains(previousToken) {
            return true
        }

        guard previousToken == "request" || previousToken == "requests",
              previousIndex > tokens.startIndex
        else { return false }

        return tokens[tokens.index(before: previousIndex)].lowercased() == "pull"
    }

    private static func repositoryHeadingTokenQueries(
        _ token: String,
        repositoryFullName: String,
        allowsCommitHash: Bool
    ) -> [GitHubReferenceQuery] {
        let bareSeriesQueries = self.compoundBareIssueQueries(from: token)
        if bareSeriesQueries.isEmpty == false {
            return bareSeriesQueries.map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
        }

        let compoundQueries = self.compoundRepositoryIssueQueries(from: token)
        if compoundQueries.isEmpty == false {
            return compoundQueries
        }

        if let query = self.urlQuery(from: token) {
            return [query]
        }
        if let query = self.tokenQuery(
            from: token,
            minimumBareDigits: 1,
            allowBareIssueNumber: false,
            allowNumericCommitHash: allowsCommitHash
        ) {
            if case .commitHash = query, allowsCommitHash == false {
                return []
            }
            return [self.applyingRepositoryContext(repositoryFullName, to: query)]
        }
        return []
    }

    private static func repositoryHeadingBackReferenceQueries(
        in line: String,
        repositoryFullName: String,
        minimumBareDigits: Int,
        previousHadIssueReferenceContext: Bool,
        suppression: RepositoryHeadingSuppression
    ) -> [GitHubReferenceQuery] {
        guard previousHadIssueReferenceContext else { return [] }

        return self.backReferenceBareIssueSeriesQueries(in: line, minimumBareDigits: minimumBareDigits)
            .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
            .filter { query in
                guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                      parentRepositoryFullName == repositoryFullName
                else { return true }

                return suppression.allowsHeadingRepositoryIssueNumber(number)
            }
    }

    private static func explicitRepositoryHeadingLineQueries(
        in line: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceQuery] {
        self.dedupedQueries(
            self.groupedRepositoryHeadingLineQueries(in: line) +
                self.spacedRepositoryHeadingLineQueries(in: line) +
                self.compactRepositoryHeadingLineQueries(in: line) +
                self.contextualExplicitRepositoryHeadingLineQueries(
                    in: line,
                    minimumBareDigits: minimumBareDigits
                )
        )
    }

    private static func contextualExplicitRepositoryHeadingLineQueries(
        in line: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: line)
        guard tokens.count >= 3 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        for index in tokens.indices.dropLast() {
            let repositoryFullName = tokens[index]
            guard self.isRepositoryFullName(repositoryFullName) else { continue }

            let firstReferenceIndex = tokens.index(after: index)
            guard self.tokenStartsIssueReferenceContext(tokens: tokens, index: firstReferenceIndex) else { continue }

            let segmentEnd = tokens[firstReferenceIndex...].firstIndex(where: self.isRepositoryFullName) ?? tokens.endIndex
            let rest = tokens[firstReferenceIndex ..< segmentEnd].joined(separator: " ")
            queries.append(
                contentsOf: self.contextualBareIssueQueries(in: rest, minimumBareDigits: minimumBareDigits)
                    .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
            )
        }
        return self.dedupedQueries(queries)
    }

    private static func tokenStartsIssueReferenceContext(tokens: [String], index: Array<String>.Index) -> Bool {
        guard tokens.indices.contains(index) else { return false }

        let token = tokens[index].lowercased()
        if ["pr", "prs", "issue", "issues"].contains(token) {
            return true
        }
        return self.startsPullRequestPhrase(tokens: tokens.map { $0.lowercased() }, index: index)
    }

    private static func groupedRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        guard let colon = line.firstIndex(of: ":") else { return [] }

        let prefixTokens = self.referenceTokens(in: String(line[..<colon]))
        guard let repositoryFullName = prefixTokens.last(where: self.isRepositoryFullName) else { return [] }

        return self.referenceTokens(in: String(line[line.index(after: colon)...]))
            .compactMap { token in
                guard let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false) else {
                    return nil
                }

                return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
            }
    }

    private static func spacedRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        self.dedupedQueries(self.repositoryHeadingSentenceFragments(in: line).flatMap {
            self.spacedRepositoryHeadingSentenceQueries(in: $0)
        })
    }

    private static func spacedRepositoryHeadingSentenceQueries(in sentence: String) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.count >= 2 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        for index in tokens.indices.dropLast() {
            let repositoryFullName = tokens[index]
            guard self.isRepositoryFullName(repositoryFullName) else { continue }

            var sawNumber = false
            for token in tokens[tokens.index(after: index)...] {
                if self.isRepositoryFullName(token) {
                    break
                }
                if sawNumber, self.tokenHasIssueReferenceContext(token) {
                    break
                }
                guard let number = self.issueNumber(
                    from: token,
                    minimumBareDigits: 1,
                    allowBareNumber: false
                ) else { continue }

                sawNumber = true
                queries.append(.repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number))
            }
        }
        return queries
    }

    private static func compactRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        self.dedupedQueries(self.repositoryHeadingSentenceFragments(in: line).flatMap {
            self.compactRepositoryHeadingSentenceQueries(in: $0)
        })
    }

    private static func compactRepositoryHeadingSentenceQueries(in sentence: String) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.count >= 2 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        var currentRepositoryFullName: String?
        var currentRepositorySawNumber = false
        for token in tokens {
            if let repositoryIssueQuery = self.repositoryIssueQuery(from: token) {
                if case let .repositoryIssueNumber(repositoryFullName, _) = repositoryIssueQuery {
                    currentRepositoryFullName = repositoryFullName
                    currentRepositorySawNumber = true
                    queries.append(repositoryIssueQuery)
                    continue
                }
            }
            if self.isRepositoryFullName(token) {
                currentRepositoryFullName = nil
                currentRepositorySawNumber = false
                continue
            }
            if currentRepositorySawNumber, self.tokenHasIssueReferenceContext(token) {
                currentRepositoryFullName = nil
                currentRepositorySawNumber = false
                continue
            }
            guard let currentRepositoryFullName,
                  let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false)
            else { continue }

            currentRepositorySawNumber = true
            queries.append(.repositoryIssueNumber(repositoryFullName: currentRepositoryFullName, number: number))
        }
        return queries
    }

    private static func repositoryHeadingSentenceFragments(in line: String) -> [String] {
        var fragments: [String] = []
        var fragmentStart = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let nextIndex = line.index(after: index)
            let character = line[index]
            let isSentencePunctuation = character == "." || character == "!" || character == "?" || character == ";"
            let isBoundary = nextIndex == line.endIndex || line[nextIndex].isWhitespace
            if isSentencePunctuation, isBoundary {
                fragments.append(String(line[fragmentStart ..< index]))
                fragmentStart = nextIndex
            }
            index = nextIndex
        }
        fragments.append(String(line[fragmentStart...]))
        return fragments
    }

    private static func tokenHasIssueReferenceContext(_ token: String) -> Bool {
        ["pr", "prs", "issue", "issues", "pull"].contains(token.lowercased())
    }

    private static func repositoryIssueQuery(from token: String) -> GitHubReferenceQuery? {
        guard let query = self.tokenQuery(
            from: token,
            minimumBareDigits: 1,
            allowBareIssueNumber: false,
            allowNumericCommitHash: false
        ),
            case .repositoryIssueNumber = query
        else { return nil }

        return query
    }

    private static func headingChildHasIssueReferenceContext(_ line: String) -> Bool {
        let lastSentence = line
            .split { character in
                character == "." || character == "!" || character == "?"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.isEmpty == false }
        guard let lastSentence else { return false }

        return self.isIssueCountSummary(lastSentence) == false && self.hasIssueReferenceContext(lastSentence)
    }

    private static func headingChildHasCommitContext(_ line: String) -> Bool {
        let normalized = line.lowercased()
        return normalized.contains("sha") || normalized.contains("commit") || normalized.contains("hash")
    }
}

private struct RepositoryHeadingSuppression {
    let explicitLineNumbers: Set<Int>
    let headingTokenNumbers: Set<Int>

    func allowsHeadingRepositoryIssueNumber(_ number: Int) -> Bool {
        self.explicitLineNumbers.contains(number) == false ||
            self.headingTokenNumbers.contains(number)
    }
}

private struct RepositoryHeadingTokenOptions {
    let repositoryFullName: String
    let allowsCommitHash: Bool
    let allowsContextualBareIssueNumber: Bool
    let explicitLineNumbers: Set<Int>
    let firstExplicitRepositoryIndex: Int?
    let minimumBareDigits: Int
}

private func repositoryHeadingDedupeKey(for query: GitHubReferenceQuery) -> String {
    switch query {
    case let .issueNumber(number):
        "issue:\(number)"
    case let .repositoryNameIssueNumber(repositoryName, number):
        "repo-name:\(repositoryName.lowercased())#\(number)"
    case let .repositoryIssueNumber(repositoryFullName, number):
        "repo:\(repositoryFullName.lowercased())#\(number)"
    case let .commitHash(hash):
        "commit:\(hash.lowercased())"
    case let .repositoryCommitHash(repositoryFullName, hash):
        "repo:\(repositoryFullName.lowercased())@\(hash.lowercased())"
    case let .repositoryWorkflowRun(repositoryFullName, runID):
        "repo:\(repositoryFullName.lowercased())/run/\(runID)"
    }
}

private extension GitHubReferenceQuery {
    var repositoryIssueNumber: Int? {
        guard case let .repositoryIssueNumber(_, number) = self else { return nil }

        return number
    }
}
