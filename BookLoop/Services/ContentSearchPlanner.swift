import Foundation

final class ContentSearchPlanner {
    private let client = OpenAIClient()

    func plan(
        naturalLanguageQuery: String,
        project: BookProject,
        scope: SearchScope,
        apiKey: String,
        model: String
    ) async throws -> SearchPlan {
        let trimmed = naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallbackPlan(query: trimmed, scope: scope)
        }

        let system = """
        You translate book-project search requests into local search strategies.
        Return ONLY valid JSON matching this schema (no markdown fences):
        {
          "summary": "short explanation of what you will search for",
          "searches": [
            {
              "method": "grep" | "search_text",
              "pattern": "regex when method is grep",
              "query": "substring when method is search_text",
              "glob": "optional glob such as docs/**/*.md or **/*",
              "path": "optional project-relative directory prefix",
              "ignore_case": true,
              "fixed_strings": false,
              "limit": 50,
              "rationale": "why this query helps"
            }
          ]
        }
        Rules:
        - Prefer search_text for simple topic or phrase presence checks.
        - Use grep with regex for variants, word boundaries, acronyms plus long forms, or multiple phrasings.
        - Return 1 to 3 searches when helpful (e.g. acronym + spelled-out term).
        - Default glob for this scope: \(scope.defaultGlob)
        - Never invent absolute file paths; use globs only.
        - Keep patterns safe and reasonably bounded; avoid catastrophic backtracking.
        """

        let user = """
        Scope: \(scope.displayName) (default glob: \(scope.defaultGlob))
        Project: \(project.projectMap.compactSummary)
        Chapters:
        \(chapterContext(from: project))

        User request: \(trimmed)
        """

        let reply = try await client.sendChat(
            apiKey: apiKey,
            model: model,
            messages: [
                OpenAIChatMessage(role: "system", content: system),
                OpenAIChatMessage(role: "user", content: user)
            ]
        )

        if let parsed = parsePlan(from: reply) {
            return parsed
        }
        return fallbackPlan(query: trimmed, scope: scope)
    }

    func fallbackPlan(query: String, scope: SearchScope) -> SearchPlan {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchPlan(
            summary: trimmed.isEmpty
                ? "Enter a search description."
                : "Literal substring search for \"\(trimmed)\".",
            searches: [
                SearchQuery(
                    method: .searchText,
                    query: trimmed,
                    glob: scope.defaultGlob,
                    limit: 50,
                    rationale: "Direct text match without AI planning."
                )
            ]
        )
    }

    func execute(
        plan: SearchPlan,
        scope: SearchScope,
        project: BookProject,
        searchIndex: SearchIndex
    ) throws -> [ContentSearchResult] {
        let batches: [[ContentSearchResult]] = try plan.searches.enumerated().map { index, query in
            try ProjectContentSearch.execute(
                query: query,
                scope: scope,
                project: project,
                searchIndex: searchIndex
            ).map { match in
                ContentSearchResult(
                    relativePath: match.relativePath,
                    lineNumber: match.lineNumber,
                    snippet: match.snippet,
                    sourceQueryIndex: index
                )
            }
        }
        return ProjectContentSearch.mergeResults(batches)
    }

    private func chapterContext(from project: BookProject) -> String {
        let chapters = project.projectMap.files
            .filter { $0.kind == .chapter }
            .prefix(30)
        guard !chapters.isEmpty else { return "- (no chapters indexed)" }
        return chapters.map { file in
            let headings = file.headings.prefix(3).joined(separator: " | ")
            if headings.isEmpty {
                return "- \(file.relativePath): \(file.title)"
            }
            return "- \(file.relativePath): \(file.title) — \(headings)"
        }.joined(separator: "\n")
    }

    private func parsePlan(from text: String) -> SearchPlan? {
        let trimmed = stripJSONFences(text)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SearchPlan.self, from: data)
    }

    private func stripJSONFences(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```json", with: "")
            value = value.replacingOccurrences(of: "```", with: "")
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}") {
            return String(value[start...end])
        }
        return value
    }
}
