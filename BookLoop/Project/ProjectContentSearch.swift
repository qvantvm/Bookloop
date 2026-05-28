import Foundation

enum ProjectContentSearch {
    static let searchableExtensions: Set<String> = [
        "md", "markdown", "txt", "yml", "yaml", "json", "patch", "diff",
        "css", "js", "ts", "swift", "py", "sh", "toml", "xml", "html", "htm"
    ]

    static func searchText(
        query: String,
        glob: String?,
        limit: Int,
        project: BookProject,
        searchIndex: SearchIndex
    ) -> [SearchResult] {
        searchIndex.searchText(
            query,
            glob: glob,
            limit: limit,
            book: project.book,
            config: project.config
        )
    }

    static func grep(
        pattern: String,
        glob: String?,
        path: String?,
        ignoreCase: Bool,
        fixedStrings: Bool,
        limit: Int,
        project: BookProject
    ) throws -> GrepResponse {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            return GrepResponse(pattern: pattern, matches: [], filesSearched: 0, truncated: false)
        }

        let maxMatches = max(1, min(limit, 200))
        let pathPrefix = normalizedPathPrefix(path)
        let effectiveGlob = glob?.nilIfBlank ?? "**/*"
        let candidatePaths = project.projectMap.relativePaths(matchingGlob: effectiveGlob)
            .filter { relative in
                guard let pathPrefix else { return true }
                return relative == pathPrefix || relative.hasPrefix(pathPrefix + "/")
            }
            .filter { isGrepCandidatePath($0) }

        let regex = try grepRegex(pattern: trimmedPattern, ignoreCase: ignoreCase, fixedStrings: fixedStrings)

        var matches: [SearchResult] = []
        var filesSearched = 0

        try project.withSecurityScoped {
            for relativePath in candidatePaths {
                if matches.count >= maxMatches { break }
                guard let url = try? project.pathGuard.validateRead(relativePath),
                      let content = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                filesSearched += 1
                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    if lineMatches(line, regex: regex, fixedStrings: fixedStrings, pattern: trimmedPattern, ignoreCase: ignoreCase) {
                        matches.append(SearchResult(
                            relativePath: relativePath,
                            lineNumber: index + 1,
                            snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(300))
                        ))
                        if matches.count >= maxMatches { break }
                    }
                }
            }
        }

        return GrepResponse(
            pattern: trimmedPattern,
            matches: matches,
            filesSearched: filesSearched,
            truncated: matches.count >= maxMatches
        )
    }

    static func execute(
        query: SearchQuery,
        scope: SearchScope,
        project: BookProject,
        searchIndex: SearchIndex
    ) throws -> [SearchResult] {
        let glob = query.glob?.nilIfBlank ?? scope.defaultGlob
        let limit = max(1, min(query.limit, 200))

        switch query.method {
        case .grep:
            let pattern = query.pattern?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? ""
            guard !pattern.isEmpty else { return [] }
            return try grep(
                pattern: pattern,
                glob: glob,
                path: query.path,
                ignoreCase: query.ignoreCase,
                fixedStrings: query.fixedStrings,
                limit: limit,
                project: project
            ).matches.filter { scope.matchesPath($0.relativePath) }
        case .searchText:
            let text = query.query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? ""
            guard !text.isEmpty else { return [] }
            return searchText(
                query: text,
                glob: glob,
                limit: limit,
                project: project,
                searchIndex: searchIndex
            ).filter { scope.matchesPath($0.relativePath) }
        }
    }

    static func mergeResults(_ batches: [[ContentSearchResult]]) -> [ContentSearchResult] {
        var seen = Set<String>()
        var merged: [ContentSearchResult] = []
        for batch in batches {
            for result in batch {
                guard seen.insert(result.id).inserted else { continue }
                merged.append(result)
            }
        }
        return merged.sorted {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return $0.lineNumber < $1.lineNumber
        }
    }

    private static func normalizedPathPrefix(_ path: String?) -> String? {
        guard var value = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else { return nil }
        value = value.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty ? nil : value
    }

    private static func isGrepCandidatePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return searchableExtensions.contains(ext)
    }

    private static func grepRegex(pattern: String, ignoreCase: Bool, fixedStrings: Bool) throws -> NSRegularExpression? {
        guard !fixedStrings else { return nil }
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw AgentToolError.invalidGrepPattern(pattern)
        }
    }

    private static func lineMatches(
        _ line: String,
        regex: NSRegularExpression?,
        fixedStrings: Bool,
        pattern: String,
        ignoreCase: Bool
    ) -> Bool {
        if fixedStrings {
            if ignoreCase {
                return line.range(of: pattern, options: .caseInsensitive) != nil
            }
            return line.contains(pattern)
        }
        guard let regex else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}
