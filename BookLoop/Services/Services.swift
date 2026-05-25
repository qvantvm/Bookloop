import Foundation

final class FeedbackAPIClient {
    func checkHealth(baseURL: String) async throws -> HealthResponse {
        try await LocalHTTPClient().get(baseURL: baseURL, path: "/api/health")
    }

    func submitReview(baseURL: String, request: ReviewRequest) async throws -> ReviewResponse {
        try await LocalHTTPClient().post(baseURL: baseURL, path: "/api/review", body: request)
    }
}

final class PreviewHealthChecker {
    func check(previewURL: String) async -> LocalAPIStatus {
        let value = previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "http" || url.scheme == "https" else {
            if FileManager.default.fileExists(atPath: value) {
                return .online
            }
            return .offline("Preview URL is not a valid HTTP(S) URL or existing file path.")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .offline("Preview returned a non-HTTP response.")
            }
            return (200..<500).contains(http.statusCode) ? .online : .offline("Preview returned HTTP \(http.statusCode).")
        } catch {
            return .offline("MkDocs preview appears offline. Start it from the book root with `mkdocs serve`.")
        }
    }
}

private final class LocalHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func get<T: Decodable>(baseURL: String, path: String) async throws -> T {
        let url = try endpoint(baseURL: baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    func post<B: Encodable, T: Decodable>(baseURL: String, path: String, body: B) async throws -> T {
        let url = try endpoint(baseURL: baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.pretty.encode(body)
        return try await perform(request)
    }

    private func endpoint(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        guard let base = URL(string: trimmed), base.scheme != nil, base.host != nil else {
            throw FeedbackAPIError.invalidBaseURL
        }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FeedbackAPIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FeedbackAPIError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
            }
            do {
                return try JSONDecoder.flexibleDates.decode(T.self, from: data)
            } catch {
                throw FeedbackAPIError.decodingFailed(error.localizedDescription)
            }
        } catch let apiError as FeedbackAPIError {
            throw apiError
        } catch {
            throw FeedbackAPIError.transportError(error.localizedDescription)
        }
    }
}

final class MkDocsProjectScanner {
    func discoverChapters(book: BookConfig) throws -> [Chapter] {
        var chaptersByPath: [String: Chapter] = [:]
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        let fm = FileManager.default

        if let mkdocsPath = book.mkdocsConfigPath ?? existing(book.suggestedPath("mkdocs.yml")),
           let content = try? String(contentsOfFile: mkdocsPath, encoding: .utf8) {
            for (order, entry) in parseMkDocsNav(content: content, docsURL: docsURL).enumerated() {
                var chapter = entry
                chapter.order = order
                chaptersByPath[chapter.markdownPath] = chapter
            }
        }

        guard fm.fileExists(atPath: docsURL.path) else {
            return chaptersByPath.values.sorted {
                let leftOrder = $0.order ?? Int.max
                let rightOrder = $1.order ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }

        if let enumerator = fm.enumerator(at: docsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                if chaptersByPath[url.path] == nil {
                    chaptersByPath[url.path] = chapterFromMarkdown(url: url, docsURL: docsURL, order: nil)
                }
            }
        }

        return chaptersByPath.values.sorted {
            if $0.order != $1.order { return ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func parseMkDocsNav(content: String, docsURL: URL) -> [Chapter] {
        content
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.contains(".md") else { return nil }
                let cleaned = line
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.nilIfBlank
            }
            .compactMap { entry in
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                let title: String?
                let pathPart: String
                if parts.count == 2 {
                    title = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    pathPart = parts[1]
                } else {
                    title = nil
                    pathPart = parts[0]
                }
                let markdown = normalizedDocsRelativeMarkdownPath(pathPart.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                guard markdown.hasSuffix(".md") else { return nil }
                return chapterFromMarkdown(url: docsURL.appendingPathComponent(markdown), docsURL: docsURL, titleOverride: title, order: nil)
            }
    }

    private func chapterFromMarkdown(url: URL, docsURL: URL, titleOverride: String? = nil, order: Int?) -> Chapter {
        let docsPath = docsURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relativePath = filePath.hasPrefix(docsPath + "/")
            ? String(filePath.dropFirst(docsPath.count + 1))
            : url.lastPathComponent
        relativePath = ChapterResolver.normalizedDocsRelativeMarkdownPath(relativePath)
        let frontmatter = parseFrontmatter(path: url.path)
        let id = frontmatter["id"] ?? relativePath.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")
        let title = titleOverride ?? frontmatter["title"] ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized
        let slug = relativePath == "index.md" ? "" : relativePath.replacingOccurrences(of: ".md", with: "/").replacingOccurrences(of: "index/", with: "")
        return Chapter(id: id, title: title, markdownPath: url.path, relativePath: relativePath, urlSlug: slug.nilIfBlank, order: order)
    }

    private func normalizedDocsRelativeMarkdownPath(_ path: String) -> String {
        ChapterResolver.normalizedDocsRelativeMarkdownPath(path)
    }

    private func parseFrontmatter(path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              content.hasPrefix("---") else { return [:] }
        let lines = content.components(separatedBy: .newlines)
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return result
    }

    private func existing(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

enum ChapterResolver {
    /// Chapter id for `POST /api/review`. The feedback API resolves this to `docs/{id}.md`.
    static func feedbackAPIChapterID(_ raw: String, book: BookConfig, chapters: [Chapter], currentURL: URL? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let normalizedID = normalizedAPIChapterID(trimmed, book: book)

        if chapters.contains(where: { $0.id == normalizedID }) {
            return normalizedID
        }

        if let match = matchChapter(for: trimmed, book: book, chapters: chapters) {
            return match.id
        }

        if let currentURL,
           let match = matchChapter(forPreviewURL: currentURL, book: book, chapters: chapters) {
            return match.id
        }

        if let match = chapters.first(where: { matchesStem($0, stem: normalizedID) }) {
            return match.id
        }

        return normalizedID
    }

    static func feedbackAPIChapterExists(_ chapterID: String, book: BookConfig) -> Bool {
        let normalized = normalizedAPIChapterID(chapterID, book: book)
        guard !normalized.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: book.suggestedPath("docs/\(normalized).md"))
    }

    static func normalizedAPIChapterID(_ raw: String, book: BookConfig? = nil) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let book {
            let root = book.projectRootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if result.hasPrefix(root + "/") {
                result = String(result.dropFirst(root.count + 1))
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while result.hasPrefix("docs/") {
            result = String(result.dropFirst("docs/".count))
        }
        while result.hasSuffix(".md") {
            result = String(result.dropLast(".md".count))
        }
        if result.contains("/") {
            result = result.replacingOccurrences(of: "/", with: "-")
        }
        return result
    }

    static func resolve(_ raw: String, book: BookConfig, chapters: [Chapter], currentURL: URL? = nil) -> String {
        feedbackAPIChapterID(raw, book: book, chapters: chapters, currentURL: currentURL)
    }

    static func exists(_ chapterID: String, book: BookConfig) -> Bool {
        feedbackAPIChapterExists(chapterID, book: book)
    }

    static func normalizedDocsRelativeMarkdownPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while result.hasPrefix("docs/") {
            result = String(result.dropFirst("docs/".count))
        }
        while result.hasSuffix(".md.md") {
            result = String(result.dropLast(".md".count))
        }
        return result
    }

    static func normalizedProjectRelativeMarkdownPath(_ path: String, book: BookConfig) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = book.projectRootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if result.hasPrefix(root + "/") {
            result = String(result.dropFirst(root.count + 1))
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while result.hasPrefix("docs/docs/") {
            result = String(result.dropFirst("docs/".count))
        }
        if !result.hasPrefix("docs/"), !result.isEmpty {
            result = "docs/\(normalizedDocsRelativeMarkdownPath(result))"
        } else if result.hasPrefix("docs/") {
            result = "docs/\(normalizedDocsRelativeMarkdownPath(String(result.dropFirst("docs/".count))))"
        }
        while result.hasSuffix(".md.md") {
            result = String(result.dropLast(".md".count))
        }
        return result
    }

    private static func matchChapter(for value: String, book: BookConfig, chapters: [Chapter]) -> Chapter? {
        chapters.first { matches($0, value: value, book: book) }
    }

    private static func matchChapter(forPreviewURL url: URL, book: BookConfig, chapters: [Chapter]) -> Chapter? {
        if let slug = url.detectedChapterSlug?.nilIfBlank {
            if let match = chapters.first(where: { matchesSlug($0, slug: slug) }) {
                return match
            }
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return chapters.first { $0.relativePath == "index.md" || $0.urlSlug?.nilIfBlank == nil }
        }

        return nil
    }

    private static func matches(_ chapter: Chapter, value: String, book: BookConfig) -> Bool {
        let normalizedValue = normalizedAPIChapterID(value, book: book)
        let projectPath = projectRelativePath(for: chapter, book: book)
        let optionalCandidates: [String?] = [
            chapter.id,
            chapter.relativePath,
            chapter.urlSlug?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            chapter.urlSlug,
            chapter.markdownPath,
            projectPath,
            "docs/\(chapter.relativePath)",
            chapter.relativePath.replacingOccurrences(of: ".md", with: "")
        ]
        let candidates = optionalCandidates.compactMap { $0?.nilIfBlank }

        if candidates.contains(value) || chapter.id == normalizedValue {
            return true
        }

        let stem = normalizedValue
        return matchesStem(chapter, stem: stem)
    }

    private static func matchesStem(_ chapter: Chapter, stem: String) -> Bool {
        guard !stem.isEmpty else { return false }
        let relativeStem = chapter.relativePath.replacingOccurrences(of: ".md", with: "")
        let stemWithoutExtension = stem.hasSuffix(".md") ? String(stem.dropLast(".md".count)) : stem
        return chapter.id == stem
            || chapter.id == stemWithoutExtension
            || relativeStem == stem
            || relativeStem == stemWithoutExtension
            || chapter.relativePath == markdownFilename(forStem: stem)
            || chapter.urlSlug?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == stem
            || chapter.urlSlug?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == stemWithoutExtension
    }

    private static func markdownFilename(forStem stem: String) -> String {
        stem.hasSuffix(".md") ? stem : "\(stem).md"
    }

    private static func matchesSlug(_ chapter: Chapter, slug: String) -> Bool {
        let normalizedSlug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedSlug.isEmpty else {
            return chapter.relativePath == "index.md"
        }
        return matchesStem(chapter, stem: normalizedSlug)
            || chapter.urlSlug?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedSlug
    }

    private static func projectRelativePath(for chapter: Chapter, book: BookConfig) -> String {
        let rootURL = URL(fileURLWithPath: book.projectRootPath, isDirectory: true).standardizedFileURL
        let markdownURL = URL(fileURLWithPath: chapter.markdownPath).standardizedFileURL
        if markdownURL.path.hasPrefix(rootURL.path + "/") {
            let relative = String(markdownURL.path.dropFirst(rootURL.path.count + 1))
            return normalizedProjectRelativeMarkdownPath(relative, book: book)
        }
        return normalizedProjectRelativeMarkdownPath("docs/\(chapter.relativePath)", book: book)
    }
}

final class ReviewItemParser {
    func parseReviewItems(book: BookConfig) throws -> [ReviewItem] {
        let directory = URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap(parse(url:))
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func readOptional(path: String?) -> String? {
        guard let path else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func parse(url: URL) -> ReviewItem? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(content)
        let id = frontmatter["id"] ?? url.deletingPathExtension().lastPathComponent
        let title = frontmatter["title"] ?? firstHeading(content) ?? id
        let status = ReviewStatus(rawValue: frontmatter["status"] ?? "") ?? .open
        let createdAt = parseDate(frontmatter["created_at"]) ?? parseDateFromFilename(url.deletingPathExtension().lastPathComponent) ?? url.modificationDate

        return ReviewItem(
            id: id,
            filePath: url.path,
            chapter: value(frontmatter, keys: ["chapter", "chapter_id"]),
            type: value(frontmatter, keys: ["type", "feedback_type"]),
            severity: frontmatter["severity"],
            section: frontmatter["section"],
            title: title,
            body: feedbackBody(from: content),
            suggestedFix: value(frontmatter, keys: ["suggested_fix", "suggestedFix"]) ?? section(named: ["suggested fix", "suggested_fix"], content: content),
            sourceFile: value(frontmatter, keys: ["source_file", "sourceFile"]),
            status: status,
            createdAt: createdAt
        )
    }

    private func feedbackBody(from content: String) -> String? {
        let sections = [
            section(named: ["observation"], content: content),
            section(named: ["conversation"], content: content),
            section(named: ["why this matters"], content: content),
            section(named: ["body", "review", "details"], content: content)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }

        if !sections.isEmpty {
            return sections.joined(separator: "\n\n")
        }
        return bodyWithoutFrontmatterAndTitle(content)
    }

    func conversationSection(from content: String) -> String? {
        section(named: ["conversation"], content: content)
    }

    private func isLevel2MarkdownHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("##") else { return false }
        return !trimmed.dropFirst(2).hasPrefix("#")
    }

    private func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        let lines = content.components(separatedBy: .newlines)
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return result
    }

    private func firstHeading(_ content: String) -> String? {
        content.components(separatedBy: .newlines)
            .first { $0.hasPrefix("# ") }?
            .replacingOccurrences(of: "# ", with: "")
            .nilIfBlank
    }

    private func bodyWithoutFrontmatterAndTitle(_ content: String) -> String? {
        var lines = content.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(...end)
        }
        if let firstHeading = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.remove(at: firstHeading)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func section(named names: [String], content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where isLevel2MarkdownHeading(line) {
            let heading = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard names.contains(heading) else { continue }
            let rest = lines.dropFirst(index + 1)
            let sectionLines = rest.prefix { !isLevel2MarkdownHeading($0) }
            return sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        return nil
    }

    private func value(_ dictionary: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key.lowercased()] { return value }
        }
        return nil
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string) ?? DateFormatting.taskFilename.date(from: string)
    }

    private func parseDateFromFilename(_ filename: String) -> Date? {
        guard filename.count >= 15 else { return nil }
        let prefix = String(filename.prefix(15))
        return DateFormatting.taskFilename.date(from: prefix)
    }
}

final class TaskGenerator {
    struct GeneratedTask {
        var url: URL
        var text: String
    }

    func generateTask(book: BookConfig, mode: RevisionTaskMode, chapterID: String?, reviewItems: [ReviewItem], selectedText: String?) throws -> GeneratedTask {
        let directory = URL(fileURLWithPath: book.taskDirectoryPath, isDirectory: true)
        try FileHelpers.ensureDirectory(directory.path)
        let chapter = chapterID ?? reviewItems.compactMap(\.chapter).first
        let date = Date()
        let filename = "\(DateFormatting.taskFilename.string(from: date))-\(mode.rawValue.replacingOccurrences(of: "_", with: "-"))-\((chapter ?? "book").slugified()).md"
        let url = directory.appendingPathComponent(filename)
        let text = taskText(book: book, mode: mode, chapterID: chapter, reviewItems: reviewItems, selectedText: selectedText, createdAt: date)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return GeneratedTask(url: url, text: text)
    }

    private func taskText(book: BookConfig, mode: RevisionTaskMode, chapterID: String?, reviewItems: [ReviewItem], selectedText: String?, createdAt: Date) -> String {
        let reviewIDs = reviewItems.map(\.id)
        let title: String
        switch mode {
        case .proposeFigure:
            title = "Create a script-generated figure for chapter `\(chapterID ?? "current")`."
        case .validateBook:
            title = "Validate the MkDocs book and report issues."
        case .planOnly:
            title = "Plan revisions for the selected book context."
        case .proposePatchOnly, .fixReviews:
            if let chapterID {
                title = "Fix selected review items in chapter `\(chapterID)`."
            } else {
                title = "Fix selected review items."
            }
        }

        var lines: [String] = [
            "# BookLoop Revision Task",
            "",
            "Created: \(ISO8601DateFormatter().string(from: createdAt))",
            "",
            "## Task",
            title,
            "",
            "## Mode",
            modeInstruction(mode),
            "",
            "## Book",
            "- Name: \(book.displayName)",
            "- Root: \(book.projectRootPath)",
            "",
            "## Chapter",
            chapterID ?? "Not specified",
            "",
            "## Review Items"
        ]

        lines.append(contentsOf: reviewIDs.isEmpty ? ["- None selected"] : reviewIDs.map { "- \($0)" })

        if !reviewItems.isEmpty {
            lines.append(contentsOf: ["", "## Review Item Details"])
            for item in reviewItems {
                lines.append(contentsOf: [
                    "### \(item.title)",
                    "- ID: \(item.id)",
                    "- Chapter: \(item.chapter ?? "Unknown")",
                    "- Type: \(item.type ?? "Unknown")",
                    "- Severity: \(item.severity ?? "Unknown")",
                    "",
                    item.body ?? ""
                ])
                if let suggestedFix = item.suggestedFix {
                    lines.append(contentsOf: ["", "Suggested fix:", suggestedFix])
                }
                lines.append("")
            }
        }

        if let selectedText = selectedText?.nilIfBlank {
            lines.append(contentsOf: [
                "",
                "## Selected Passage",
                "",
                selectedText.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            ])
        }

        if mode == .proposeFigure {
            lines.append(contentsOf: figureRequirements(chapterID: chapterID, reviewItems: reviewItems))
        }

        if mode == .validateBook {
            lines.append(contentsOf: validationRequirements())
        }

        lines.append(contentsOf: [
            "",
            "## Constraints",
            "- Preserve chapter voice.",
            "- Add concrete examples where useful.",
            "- Do not introduce unsupported benchmark claims.",
            "- Do not rewrite the whole chapter unless necessary.",
            "- Return a unified diff.",
            "- Run `mkdocs build` if possible.",
            "- If a figure is needed, generate a script-based figure rather than only a static image.",
            "- Do not directly apply changes; BookLoop must review the patch first.",
            "",
            "## Expected Output",
            "- Revision summary",
            "- Files changed",
            "- Unified patch",
            "- Validation result",
            "- Review items addressed",
            "- Review items not addressed and why"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    private func modeInstruction(_ mode: RevisionTaskMode) -> String {
        switch mode {
        case .proposePatchOnly:
            return "Propose patch only. Do not directly apply changes."
        case .planOnly:
            return "Plan only. Do not edit files or produce a patch unless asked in a later task."
        case .proposeFigure:
            return "Propose a reproducible figure and return all changes as a visible patch."
        case .fixReviews:
            return "Fix selected reviews by proposing a unified diff. Do not directly apply changes."
        case .validateBook:
            return "Run validation such as `mkdocs build` and report issues. Do not directly modify files."
        }
    }

    private func figureRequirements(chapterID: String?, reviewItems: [ReviewItem]) -> [String] {
        [
            "",
            "## Figure Requirements",
            "- Use a reproducible source script.",
            "- Prefer Python matplotlib, SVG, Mermaid, Graphviz, or TikZ.",
            "- Do not produce only an untraceable PNG.",
            "- Save source under `figures/<figure-id>/`.",
            "- Save final asset under `docs/assets/figures/`.",
            "- Add alt text and caption.",
            "- Insert figure into the chapter only through a visible patch.",
            "- Validate through `mkdocs build` if possible."
        ]
    }

    private func validationRequirements() -> [String] {
        [
            "",
            "## Validation Checklist",
            "- Run `mkdocs build` if possible.",
            "- Check image references.",
            "- Check broken internal links.",
            "- Check stale figures.",
            "- Check missing captions or alt text.",
            "- Summarize open review items by severity."
        ]
    }
}

final class FigureScanner {
    func scan(book: BookConfig) throws -> [FigureItem] {
        var figuresByOutput: [String: FigureItem] = [:]
        let markdownReferences = scanMarkdownReferences(book: book)
        for reference in markdownReferences {
            let outputPath = resolve(reference.path, fromMarkdown: reference.markdownPath, book: book)
            let exists = FileManager.default.fileExists(atPath: outputPath)
            let source = findSource(for: outputPath, book: book)
            let stale = isStale(sourcePath: source, outputPath: outputPath)
            let status: FigureStatus = exists ? (stale ? .stale : .ok) : .missingOutput
            let existing = figuresByOutput[outputPath]
            let referencedFrom = Array(Set((existing?.referencedFrom ?? []) + [reference.markdownPath])).sorted()
            figuresByOutput[outputPath] = FigureItem(
                id: URL(fileURLWithPath: outputPath).deletingPathExtension().lastPathComponent,
                title: reference.altText.nilIfBlank,
                chapterID: reference.chapterID,
                section: nil,
                sourcePath: source,
                outputPath: outputPath,
                referencedFrom: referencedFrom,
                type: FigureScanner.type(for: outputPath),
                status: status,
                caption: reference.altText.nilIfBlank,
                generationCommand: nil,
                lastGeneratedAt: FileHelpers.modificationDate(path: outputPath),
                isStale: stale
            )
        }

        for output in scanOutputFiles(book: book) where figuresByOutput[output] == nil {
            figuresByOutput[output] = FigureItem(
                id: URL(fileURLWithPath: output).deletingPathExtension().lastPathComponent,
                title: nil,
                chapterID: nil,
                section: nil,
                sourcePath: findSource(for: output, book: book),
                outputPath: output,
                referencedFrom: [],
                type: FigureScanner.type(for: output),
                status: .unreferenced,
                caption: nil,
                generationCommand: nil,
                lastGeneratedAt: FileHelpers.modificationDate(path: output),
                isStale: isStale(sourcePath: findSource(for: output, book: book), outputPath: output)
            )
        }

        for registryFigure in scanRegistry(book: book) {
            if var existing = figuresByOutput[registryFigure.outputPath] {
                existing.title = existing.title ?? registryFigure.title
                existing.sourcePath = existing.sourcePath ?? registryFigure.sourcePath
                existing.caption = existing.caption ?? registryFigure.caption
                existing.generationCommand = existing.generationCommand ?? registryFigure.generationCommand
                existing.chapterID = existing.chapterID ?? registryFigure.chapterID
                existing.section = existing.section ?? registryFigure.section
                existing.isStale = existing.isStale || registryFigure.isStale
                if existing.status == .unreferenced && !existing.referencedFrom.isEmpty {
                    existing.status = registryFigure.status
                }
                figuresByOutput[registryFigure.outputPath] = existing
            } else {
                figuresByOutput[registryFigure.outputPath] = registryFigure
            }
        }

        return figuresByOutput.values.sorted {
            let leftChapter = $0.chapterID ?? ""
            let rightChapter = $1.chapterID ?? ""
            if leftChapter != rightChapter {
                return leftChapter.localizedStandardCompare(rightChapter) == .orderedAscending
            }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private struct MarkdownReference {
        var markdownPath: String
        var path: String
        var altText: String
        var chapterID: String?
    }


    private func scanRegistry(book: BookConfig) -> [FigureItem] {
        guard let path = book.figuresRegistryPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let dictionaries = flattenFigureDictionaries(json)
        return dictionaries.compactMap { dictionary in
            guard let output = stringValue(dictionary, keys: ["outputPath", "output_path", "output", "assetPath", "asset_path"]) else { return nil }
            let outputPath = resolveRegistryPath(output, book: book)
            let source = stringValue(dictionary, keys: ["sourcePath", "source_path", "source", "scriptPath", "script_path"]).map { resolveRegistryPath($0, book: book) } ?? findSource(for: outputPath, book: book)
            let exists = FileManager.default.fileExists(atPath: outputPath)
            let stale = isStale(sourcePath: source, outputPath: outputPath)
            return FigureItem(
                id: stringValue(dictionary, keys: ["id", "figureID", "figure_id"]) ?? URL(fileURLWithPath: outputPath).deletingPathExtension().lastPathComponent,
                title: stringValue(dictionary, keys: ["title", "name"]),
                chapterID: stringValue(dictionary, keys: ["chapterID", "chapter_id", "chapter"]),
                section: stringValue(dictionary, keys: ["section"]),
                sourcePath: source,
                outputPath: outputPath,
                referencedFrom: [],
                type: FigureScanner.type(for: outputPath),
                status: exists ? (stale ? .stale : .ok) : .missingOutput,
                caption: stringValue(dictionary, keys: ["caption", "alt", "altText", "alt_text"]),
                generationCommand: stringValue(dictionary, keys: ["generationCommand", "generation_command", "command"]),
                lastGeneratedAt: FileHelpers.modificationDate(path: outputPath),
                isStale: stale
            )
        }
    }

    private func flattenFigureDictionaries(_ value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.flatMap(flattenFigureDictionaries)
        }
        if let dictionary = value as? [String: Any] {
            var results: [[String: Any]] = []
            if stringValue(dictionary, keys: ["outputPath", "output_path", "output", "assetPath", "asset_path"]) != nil {
                results.append(dictionary)
            }
            for nested in dictionary.values {
                results.append(contentsOf: flattenFigureDictionaries(nested))
            }
            return results
        }
        return []
    }

    private func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, let trimmed = value.nilIfBlank {
                return trimmed
            }
        }
        return nil
    }

    private func resolveRegistryPath(_ value: String, book: BookConfig) -> String {
        if value.hasPrefix("/") {
            return value
        }
        return URL(fileURLWithPath: book.projectRootPath, isDirectory: true).appendingPathComponent(value).standardizedFileURL.path
    }

    private func scanMarkdownReferences(book: BookConfig) -> [MarkdownReference] {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
        var references: [MarkdownReference] = []

        for case let markdownURL as URL in enumerator where markdownURL.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: markdownURL, encoding: .utf8),
                  let regex else { continue }
            let ns = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            let chapterID = markdownURL.deletingPathExtension().lastPathComponent
            for match in matches where match.numberOfRanges >= 3 {
                let alt = ns.substring(with: match.range(at: 1))
                let path = ns.substring(with: match.range(at: 2)).components(separatedBy: " ").first ?? ""
                guard !path.hasPrefix("http://"), !path.hasPrefix("https://") else { continue }
                references.append(MarkdownReference(markdownPath: markdownURL.path, path: path, altText: alt, chapterID: chapterID))
            }
        }

        return references
    }

    private func resolve(_ reference: String, fromMarkdown markdownPath: String, book: BookConfig) -> String {
        let cleaned = reference.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        if cleaned.hasPrefix("/") {
            return URL(fileURLWithPath: book.docsPath ?? book.suggestedPath("docs"), isDirectory: true)
                .appendingPathComponent(String(cleaned.dropFirst()))
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: markdownPath)
            .deletingLastPathComponent()
            .appendingPathComponent(cleaned)
            .standardizedFileURL
            .path
    }

    private func scanOutputFiles(book: BookConfig) -> [String] {
        let directory = URL(fileURLWithPath: book.figuresOutputPath ?? book.suggestedPath("docs/assets/figures"), isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL else { return nil }
            return ["png", "jpg", "jpeg", "svg", "pdf", "gif"].contains(url.pathExtension.lowercased()) ? url.path : nil
        }
    }

    private func findSource(for outputPath: String, book: BookConfig) -> String? {
        let id = URL(fileURLWithPath: outputPath).deletingPathExtension().lastPathComponent
        let sourceRoot = URL(fileURLWithPath: book.figuresSourcePath ?? book.suggestedPath("figures"), isDirectory: true)
        let candidates = [
            sourceRoot.appendingPathComponent(id).appendingPathComponent("generate.py"),
            sourceRoot.appendingPathComponent(id).appendingPathComponent("\(id).py"),
            sourceRoot.appendingPathComponent("\(id).py"),
            sourceRoot.appendingPathComponent("\(id).mmd"),
            sourceRoot.appendingPathComponent("\(id).dot"),
            sourceRoot.appendingPathComponent("\(id).tex")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    private func isStale(sourcePath: String?, outputPath: String) -> Bool {
        guard let sourcePath,
              let sourceDate = FileHelpers.modificationDate(path: sourcePath),
              let outputDate = FileHelpers.modificationDate(path: outputPath) else { return false }
        return sourceDate > outputDate
    }

    static func type(for path: String) -> FigureType {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "py": return .python
        case "tex": return .tikz
        case "mmd", "mermaid": return .mermaid
        case "dot": return .graphviz
        case "svg": return .svg
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        default: return .unknown
        }
    }
}


final class MarkdownHTMLRenderer {
    func renderDocument(markdown: String, title: String? = nil) -> String {
        let body = renderBody(markdown)
        let safeTitle = escapeHTML(title ?? "BookLoop Patch Block")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            :root { color-scheme: light dark; }
            body {
              font: -apple-system-body;
              margin: 0;
              padding: 14px;
              line-height: 1.45;
              color: CanvasText;
              background: Canvas;
            }
            h1, h2, h3, h4 { margin: 0.8em 0 0.35em; }
            p { margin: 0.45em 0; }
            blockquote {
              border-left: 3px solid #8e8e93;
              color: #636366;
              margin: 0.6em 0;
              padding: 0.1em 0 0.1em 0.8em;
            }
            pre {
              background: rgba(127, 127, 127, 0.14);
              border-radius: 8px;
              overflow-x: auto;
              padding: 10px;
            }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            ul, ol { padding-left: 1.4em; }
            img { max-width: 100%; height: auto; }
            .empty { color: #8e8e93; font-style: italic; }
          </style>
          <title>\(safeTitle)</title>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func renderBody(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var html: [String] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false
        var inList = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>" + paragraph.map(renderInline).joined(separator: " ") + "</p>")
            paragraph.removeAll()
        }

        func closeListIfNeeded() {
            if inList {
                html.append("</ul>")
                inList = false
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    html.append("<pre><code>" + escapeHTML(codeLines.joined(separator: "\n")) + "</code></pre>")
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    closeListIfNeeded()
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                closeListIfNeeded()
                continue
            }

            if let heading = headingHTML(for: trimmed) {
                flushParagraph()
                closeListIfNeeded()
                html.append(heading)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeListIfNeeded()
                let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                html.append("<blockquote>" + renderInline(String(quote)) + "</blockquote>")
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                if !inList {
                    html.append("<ul>")
                    inList = true
                }
                html.append("<li>" + renderInline(String(trimmed.dropFirst(2))) + "</li>")
                continue
            }

            paragraph.append(trimmed)
        }

        if inCodeBlock {
            html.append("<pre><code>" + escapeHTML(codeLines.joined(separator: "\n")) + "</code></pre>")
        }
        flushParagraph()
        closeListIfNeeded()

        if html.isEmpty {
            return "<p class=\"empty\">No rendered content in this side of the block.</p>"
        }
        return html.joined(separator: "\n")
    }

    private func headingHTML(for line: String) -> String? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...4).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level + 1)
        return "<h\(level)>" + renderInline(String(text)) + "</h\(level)>"
    }

    private func renderInline(_ markdown: String) -> String {
        escapeHTML(markdown)
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum PatchFileHelpers {
    static func rootPatchStem(from filename: String) -> String {
        var stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        while stem.hasPrefix("reviewed-") {
            guard let regex = try? NSRegularExpression(pattern: "^reviewed-\\d{8}-\\d{6}-"),
                  let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  let range = Range(match.range, in: stem) else { break }
            stem = String(stem[range.upperBound...])
        }
        return stem
    }

    static func isReviewedCopy(filename: String) -> Bool {
        filename.hasPrefix("reviewed-")
    }

    @discardableResult
    static func archivePatch(at path: String, patchDirectory: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        let archiveDirectory = URL(fileURLWithPath: patchDirectory, isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true, attributes: nil)
        var destination = archiveDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let timestamp = DateFormatting.taskFilename.string(from: Date())
            destination = archiveDirectory.appendingPathComponent(
                "\(source.deletingPathExtension().lastPathComponent)-\(timestamp).\(source.pathExtension)"
            )
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination.path
    }
}

final class PatchParser {
    func scanPatchDirectory(path: String) -> [PatchProposal] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let all = files
            .filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) }
            .compactMap(parsePatch(url:))
        return deduplicateVisibleProposals(all)
    }

    private func deduplicateVisibleProposals(_ all: [PatchProposal]) -> [PatchProposal] {
        let agents = all.filter { !$0.isReviewedCopy }
        let agentRoots = Set(agents.map(\.rootStem))

        var latestReviewedByRoot: [String: PatchProposal] = [:]
        for proposal in all where proposal.isReviewedCopy {
            guard !agentRoots.contains(proposal.rootStem) else { continue }
            if let existing = latestReviewedByRoot[proposal.rootStem] {
                if (proposal.createdAt ?? .distantPast) > (existing.createdAt ?? .distantPast) {
                    latestReviewedByRoot[proposal.rootStem] = proposal
                }
            } else {
                latestReviewedByRoot[proposal.rootStem] = proposal
            }
        }

        return (agents + Array(latestReviewedByRoot.values))
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func parseDiff(_ rawPatch: String) -> [DiffFile] {
        let lines = rawPatch.components(separatedBy: .newlines)
        var files: [DiffFile] = []
        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        var oldPath = ""
        var newPath = ""

        func flushHunk() {
            guard let hunk = currentHunk else { return }
            currentFile?.hunks.append(hunk)
            currentHunk = nil
        }

        func flushFile() {
            flushHunk()
            guard let file = currentFile else { return }
            files.append(file)
            currentFile = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                let parts = line.split(separator: " ").map(String.init)
                oldPath = parts.count > 2 ? parts[2].dropGitPrefix() : ""
                newPath = parts.count > 3 ? parts[3].dropGitPrefix() : oldPath
                currentFile = DiffFile(id: "\(oldPath)->\(newPath)", oldPath: oldPath, newPath: newPath, hunks: [])
            } else if line.hasPrefix("--- ") {
                oldPath = String(line.dropFirst(4)).dropGitPrefix()
                if currentFile == nil {
                    currentFile = DiffFile(id: oldPath, oldPath: oldPath, newPath: newPath, hunks: [])
                } else {
                    currentFile?.oldPath = oldPath
                }
            } else if line.hasPrefix("+++ ") {
                newPath = String(line.dropFirst(4)).dropGitPrefix()
                currentFile?.newPath = newPath
                currentFile?.id = "\(oldPath)->\(newPath)"
            } else if line.hasPrefix("@@") {
                flushHunk()
                let parsed = parseHunkHeader(line)
                currentHunk = DiffHunk(
                    id: UUID(),
                    oldStart: parsed.oldStart,
                    oldCount: parsed.oldCount,
                    newStart: parsed.newStart,
                    newCount: parsed.newCount,
                    lines: [DiffLine(id: UUID(), kind: .header, content: line)]
                )
            } else if currentHunk != nil {
                let kind: DiffLineKind
                if line.hasPrefix("+") {
                    kind = .addition
                } else if line.hasPrefix("-") {
                    kind = .deletion
                } else {
                    kind = .context
                }
                currentHunk?.lines.append(DiffLine(id: UUID(), kind: kind, content: line))
            }
        }

        flushFile()
        return files
    }

    func renderedBlocks(from proposal: PatchProposal) -> [RenderedPatchBlock] {
        let renderer = MarkdownHTMLRenderer()
        return parseDiff(proposal.rawPatch).flatMap { file in
            file.hunks.enumerated().map { index, hunk in
                let markdown = markdownPair(for: hunk)
                let hunkHeader = hunk.lines.first(where: { $0.kind == .header })?.content ?? "@@ -\(hunk.oldStart) +\(hunk.newStart) @@"
                let title = "\(file.newPath.isEmpty ? file.oldPath : file.newPath) • block \(index + 1)"
                return RenderedPatchBlock(
                    id: "\(file.id)::\(index)::\(hunk.oldStart)-\(hunk.newStart)",
                    fileID: file.id,
                    oldPath: file.oldPath,
                    newPath: file.newPath,
                    title: title,
                    hunkHeader: hunkHeader,
                    oldStart: hunk.oldStart,
                    newStart: hunk.newStart,
                    beforeMarkdown: markdown.before,
                    afterMarkdown: markdown.after,
                    beforeHTML: renderer.renderDocument(markdown: markdown.before, title: "Before \(title)"),
                    afterHTML: renderer.renderDocument(markdown: markdown.after, title: "After \(title)"),
                    rawHunkLines: hunk.lines.map(\.content)
                )
            }
        }
    }

    func buildReviewedPatch(proposal: PatchProposal, acceptedBlockIDs: Set<String>) -> String {
        let acceptedBlocks = renderedBlocks(from: proposal).filter { acceptedBlockIDs.contains($0.id) }
        guard !acceptedBlocks.isEmpty else { return "" }

        var lines: [String] = []
        var currentFileID: String?
        for block in acceptedBlocks {
            if block.fileID != currentFileID {
                if !lines.isEmpty { lines.append("") }
                let oldDiffPath = diffGitPath(block.oldPath, fallbackPath: block.newPath, prefix: "a")
                let newDiffPath = diffGitPath(block.newPath, fallbackPath: block.oldPath, prefix: "b")
                let oldPatchPath = gitPath(block.oldPath, prefix: "a")
                let newPatchPath = gitPath(block.newPath, prefix: "b")
                lines.append("diff --git \(oldDiffPath) \(newDiffPath)")
                lines.append("--- \(oldPatchPath)")
                lines.append("+++ \(newPatchPath)")
                currentFileID = block.fileID
            }
            lines.append(contentsOf: block.rawHunkLines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    func reviewedPatchFilename(for proposal: PatchProposal) -> String {
        let root = proposal.rootStem.slugified()
        return "reviewed-\(DateFormatting.taskFilename.string(from: Date()))-\(root).patch"
    }

    private func markdownPair(for hunk: DiffHunk) -> (before: String, after: String) {
        var before: [String] = []
        var after: [String] = []

        for line in hunk.lines where line.kind != .header {
            let content = line.content
            guard !content.hasPrefix("\\ No newline") else { continue }
            switch line.kind {
            case .context:
                before.append(stripDiffPrefix(content))
                after.append(stripDiffPrefix(content))
            case .deletion:
                before.append(stripDiffPrefix(content))
            case .addition:
                after.append(stripDiffPrefix(content))
            case .header:
                break
            }
        }

        return (before.joined(separator: "\n"), after.joined(separator: "\n"))
    }

    private func stripDiffPrefix(_ line: String) -> String {
        guard let first = line.first, [" ", "+", "-"].contains(first) else { return line }
        return String(line.dropFirst())
    }

    private func diffGitPath(_ path: String, fallbackPath: String, prefix: String) -> String {
        let resolved = path == "/dev/null" ? fallbackPath : path
        return "\(prefix)/\(resolved)"
    }

    private func gitPath(_ path: String, prefix: String) -> String {
        path == "/dev/null" ? path : "\(prefix)/\(path)"
    }

    private func parsePatch(url: URL) -> PatchProposal? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let diffFiles = parseDiff(raw)
        return PatchProposal(
            id: UUID(),
            filePath: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            summary: firstPatchSummary(raw),
            createdAt: url.modificationDate,
            changedFiles: diffFiles.map(\.newPath).filter { !$0.isEmpty },
            rawPatch: raw
        )
    }

    private func firstPatchSummary(_ raw: String) -> String? {
        raw.components(separatedBy: .newlines)
            .prefix { !$0.hasPrefix("diff --git") && !$0.hasPrefix("--- ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        let regex = try? NSRegularExpression(pattern: #"@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@"#)
        let ns = line as NSString
        guard let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 5 else {
            return (0, 0, 0, 0)
        }
        func int(_ index: Int, default defaultValue: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return defaultValue }
            return Int(ns.substring(with: range)) ?? defaultValue
        }
        return (int(1, default: 0), int(2, default: 1), int(3, default: 0), int(4, default: 1))
    }
}

struct ShellCommandResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

final class ShellCommandRunner {
    func run(command: String, workingDirectory: String) throws -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ShellCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    func run(command: String, book: BookConfig) throws -> ShellCommandResult {
        try book.withSecurityScopedProjectRoot {
            try run(command: command, workingDirectory: book.projectRootPath)
        }
    }

    func runAsync(command: String, workingDirectory: String) async throws -> ShellCommandResult {
        try await Task.detached(priority: .userInitiated) {
            try self.run(command: command, workingDirectory: workingDirectory)
        }.value
    }

    func runAsync(command: String, book: BookConfig) async throws -> ShellCommandResult {
        try await Task.detached(priority: .userInitiated) {
            try book.withSecurityScopedProjectRoot {
                try self.run(command: command, workingDirectory: book.projectRootPath)
            }
        }.value
    }
}

final class PatchApplier {
    func check(patch: PatchProposal, book: BookConfig) throws -> ShellCommandResult {
        try checkPatchFile(path: patch.filePath, book: book)
    }

    func apply(patch: PatchProposal, book: BookConfig) throws -> ShellCommandResult {
        try applyPatchFile(path: patch.filePath, book: book)
    }

    func checkPatchFile(path: String, book: BookConfig) throws -> ShellCommandResult {
        try ShellCommandRunner().run(command: "git apply --check \(shellQuoted(path))", book: book)
    }

    func applyPatchFile(path: String, book: BookConfig) throws -> ShellCommandResult {
        let checkResult = try checkPatchFile(path: path, book: book)
        guard checkResult.exitCode == 0 else { return checkResult }
        return try ShellCommandRunner().run(command: "git apply \(shellQuoted(path))", book: book)
    }

    func checkAsync(patch: PatchProposal, book: BookConfig) async throws -> ShellCommandResult {
        try await checkPatchFileAsync(path: patch.filePath, book: book)
    }

    func applyAsync(patch: PatchProposal, book: BookConfig) async throws -> ShellCommandResult {
        try await applyPatchFileAsync(path: patch.filePath, book: book)
    }

    func checkPatchFileAsync(path: String, book: BookConfig) async throws -> ShellCommandResult {
        try await ShellCommandRunner().runAsync(command: "git apply --check \(shellQuoted(path))", book: book)
    }

    func applyPatchFileAsync(path: String, book: BookConfig) async throws -> ShellCommandResult {
        let checkResult = try await checkPatchFileAsync(path: path, book: book)
        guard checkResult.exitCode == 0 else { return checkResult }
        return try await ShellCommandRunner().runAsync(command: "git apply \(shellQuoted(path))", book: book)
    }

    func gitStatus(book: BookConfig) async throws -> ShellCommandResult {
        try await ShellCommandRunner().runAsync(command: "git status --short", book: book)
    }

    func gitCommit(message: String, changedPaths: [String], book: BookConfig) async throws -> ShellCommandResult {
        guard book.allowShellCommands else {
            throw PatchReviewError.shellCommandsDisabled
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw PatchReviewError.emptyCommitMessage
        }

        let addCommand: String
        let normalizedPaths = changedPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if normalizedPaths.isEmpty {
            addCommand = "git add -u"
        } else {
            addCommand = "git add " + normalizedPaths.map(shellQuoted).joined(separator: " ")
        }

        let addResult = try await ShellCommandRunner().runAsync(command: addCommand, book: book)
        guard addResult.exitCode == 0 else { return addResult }

        return try await ShellCommandRunner().runAsync(
            command: "git commit -m \(shellQuoted(trimmedMessage))",
            book: book
        )
    }

    static func suggestedCommitCommand(message: String, changedPaths: [String], book: BookConfig) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedMessage = trimmedMessage.replacingOccurrences(of: "'", with: "'\\''")
        let normalizedPaths = changedPaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let addCommand = normalizedPaths.isEmpty
            ? "git add -u"
            : "git add " + normalizedPaths.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        return """
        cd '\(book.projectRootPath.replacingOccurrences(of: "'", with: "'\\''"))'
        \(addCommand)
        git commit -m '\(escapedMessage)'
        """
    }

    private func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    func dropGitPrefix() -> String {
        if hasPrefix("a/") || hasPrefix("b/") {
            return String(dropFirst(2))
        }
        return self == "/dev/null" ? self : self
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
