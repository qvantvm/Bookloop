import Foundation

enum ReviewItemWriterError: LocalizedError {
    case chapterNotFound(String)

    var errorDescription: String? {
        switch self {
        case .chapterNotFound(let chapter):
            return "Chapter not found: docs/\(chapter).md. Use the chapter id from frontmatter, or open the page in Preview to auto-detect it."
        }
    }
}

final class ReviewItemWriter {
    func write(request: ReviewRequest, book: BookConfig) throws -> ReviewResponse {
        guard ChapterResolver.feedbackAPIChapterExists(request.chapter, book: book) else {
            throw ReviewItemWriterError.chapterNotFound(request.chapter)
        }

        return try book.withSecurityScopedProjectRoot {
            let directoryPath = book.reviewItemsPath ?? book.suggestedPath("reviews/review_items")
            try FileHelpers.ensureDirectory(directoryPath)

            let createdAt = Date()
            let timestamp = DateFormatting.taskFilename.string(from: createdAt)
            let titleSlug = request.title.slugified()
            let idSuffix = titleSlug.isEmpty ? "review" : titleSlug
            let id = "\(timestamp)-\(idSuffix)"
            let filename = "\(id).md"
            let fileURL = URL(fileURLWithPath: directoryPath).appendingPathComponent(filename)

            let rootPath = URL(fileURLWithPath: book.projectRootPath, isDirectory: true).standardizedFileURL.path
            let standardizedFile = fileURL.standardizedFileURL.path
            let relativeFile: String
            if standardizedFile.hasPrefix(rootPath) {
                relativeFile = String(standardizedFile.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                relativeFile = filename
            }

            let markdown = buildMarkdown(request: request, id: id, createdAt: createdAt)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

            return ReviewResponse(ok: true, id: id, file: relativeFile)
        }
    }

    private func buildMarkdown(request: ReviewRequest, id: String, createdAt: Date) -> String {
        var frontmatterLines = [
            "---",
            "id: \(id)",
            "title: \(yamlEscape(request.title))",
            "status: open",
            "created_at: \(ISO8601DateFormatter().string(from: createdAt))",
            "chapter: \(request.chapter)",
            "type: \(request.type)",
            "severity: \(request.severity)",
            "source_file: docs/\(request.chapter).md"
        ]
        if let section = request.section?.nilIfBlank {
            frontmatterLines.append("section: \(yamlEscape(section))")
        }
        frontmatterLines.append("---")

        var bodyLines = ["", "# \(request.title)", ""]
        if let conversationBody = conversationSection(from: request.body) {
            bodyLines.append(conversationBody)
        } else {
            bodyLines.append("## Observation")
            bodyLines.append("")
            bodyLines.append(request.body)
        }

        if let suggestedFix = request.suggested_fix?.nilIfBlank {
            bodyLines.append("")
            bodyLines.append("## Suggested fix")
            bodyLines.append("")
            bodyLines.append(suggestedFix)
        }

        return (frontmatterLines + bodyLines).joined(separator: "\n") + "\n"
    }

    private func conversationSection(from body: String) -> String? {
        guard let range = body.range(of: "## Conversation") else { return nil }
        return String(body[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func yamlEscape(_ value: String) -> String {
        if value.contains(":") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }
}

enum AnnotationReviewConverter {
    static func reviewRequest(
        quote: PreviewSelectionQuote,
        note: String,
        chapterPath: String,
        chapterID: String?,
        book: BookConfig,
        chapters: [Chapter],
        currentURL: URL?
    ) -> ReviewRequest {
        let rawChapter = chapterID?.nilIfBlank
            ?? ChapterResolver.normalizedAPIChapterID(chapterPath, book: book)
        let chapter = ChapterResolver.feedbackAPIChapterID(
            rawChapter,
            book: book,
            chapters: chapters,
            currentURL: currentURL
        )

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExact = quote.exact.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        if !trimmedNote.isEmpty {
            title = String(trimmedNote.prefix(80))
        } else if !trimmedExact.isEmpty {
            title = String(trimmedExact.prefix(80))
        } else {
            title = "Reading note"
        }

        var bodyLines = ["## Highlighted passage", ""]
        if !trimmedExact.isEmpty {
            bodyLines.append(
                trimmedExact
                    .components(separatedBy: .newlines)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
            )
        }
        if !trimmedNote.isEmpty {
            bodyLines += ["", "## Note", "", trimmedNote]
        }

        return ReviewRequest(
            chapter: chapter,
            type: FeedbackType.implementationNote.rawValue,
            severity: FeedbackSeverity.low.rawValue,
            title: title,
            body: bodyLines.joined(separator: "\n"),
            section: String(trimmedExact.prefix(120)).nilIfBlank,
            suggested_fix: nil
        )
    }

    static func reviewRequest(
        for annotation: PreviewAnnotation,
        book: BookConfig,
        chapters: [Chapter],
        currentURL: URL?
    ) -> ReviewRequest {
        reviewRequest(
            quote: annotation.quote,
            note: annotation.note,
            chapterPath: annotation.chapterPath,
            chapterID: annotation.chapterID,
            book: book,
            chapters: chapters,
            currentURL: currentURL
        )
    }
}

final class PreviewHealthChecker {
    func check(book: BookConfig) -> LocalAPIStatus {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        guard FileManager.default.fileExists(atPath: docsPath) else {
            return .offline("docs/ folder not found.")
        }
        return .online
    }
}

enum ChapterResolver {
    /// Chapter id for feedback submission. Maps to `docs/{id}.md`.
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

final class ReviewIndexParser {
    enum ParserError: LocalizedError {
        case invalidFormat(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let detail):
                return "Could not parse review_index.json: \(detail)"
            }
        }
    }

    func parse(book: BookConfig) throws -> ReviewIndexDocument? {
        let path = indexPath(for: book)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rawJSON = String(data: data, encoding: .utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.invalidFormat("root must be an object")
        }

        let lastRebuilt = parseDate(object["last_rebuilt"] as? String)
        let itemObjects = object["items"] as? [[String: Any]] ?? []
        let items = itemObjects.compactMap(parseEntry)

        return ReviewIndexDocument(lastRebuilt: lastRebuilt, items: items, rawJSON: rawJSON)
    }

    private func indexPath(for book: BookConfig) -> String {
        URL(fileURLWithPath: book.reviewsPath ?? book.suggestedPath("reviews"), isDirectory: true)
            .appendingPathComponent("review_index.json")
            .path
    }

    private func parseEntry(_ dictionary: [String: Any]) -> ReviewIndexEntry? {
        guard let id = (dictionary["id"] as? String)?.nilIfBlank else { return nil }
        let title = (dictionary["title"] as? String)?.nilIfBlank ?? id
        let chapterID = (dictionary["chapter_id"] as? String)?.nilIfBlank
            ?? (dictionary["chapter"] as? String)?.nilIfBlank
        let status = (dictionary["status"] as? String)?.nilIfBlank ?? "unknown"
        return ReviewIndexEntry(
            id: id,
            chapterID: chapterID,
            title: title,
            type: (dictionary["type"] as? String)?.nilIfBlank,
            severity: (dictionary["severity"] as? String)?.nilIfBlank,
            status: status,
            createdAt: parseDate(dictionary["created_at"] as? String),
            file: (dictionary["file"] as? String)?.nilIfBlank
        )
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        if let date = iso.date(from: raw) { return date }
        if raw.count >= 15 {
            return DateFormatting.taskFilename.date(from: String(raw.prefix(15)))
        }
        return nil
    }
}

final class ReviewItemParser {
    func parseReviewItems(book: BookConfig) throws -> [ReviewItem] {
        try parseReviewItems(in: reviewItemsDirectory(for: book), defaultStatus: .open)
    }

    func parseAllReviewItems(book: BookConfig) throws -> [ReviewItem] {
        let openItems = try parseReviewItems(book: book)
        let resolvedItems = try parseReviewItems(in: Self.resolvedDirectory(for: book), defaultStatus: .resolved)
        var byID: [String: ReviewItem] = [:]
        for item in openItems {
            byID[item.id] = item
        }
        for item in resolvedItems {
            byID[item.id] = item
        }
        return byID.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private func reviewItemsDirectory(for book: BookConfig) -> URL {
        URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
    }

    private func parseReviewItems(in directory: URL, defaultStatus: ReviewStatus) throws -> [ReviewItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent.caseInsensitiveCompare("README.md") != .orderedSame }
            .compactMap { parse(url: $0, defaultStatus: defaultStatus) }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func readOptional(path: String?) -> String? {
        guard let path else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func parse(url: URL, defaultStatus: ReviewStatus = .open) -> ReviewItem? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(content)
        let id = frontmatter["id"] ?? url.deletingPathExtension().lastPathComponent
        let title = frontmatter["title"] ?? firstHeading(content) ?? id
        let inResolvedFolder = url.path.contains("/resolved/")
        let status = Self.parseReviewStatus(frontmatter["status"], inResolvedFolder: inResolvedFolder, defaultStatus: defaultStatus)
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

    func reviewMarkdownURLs(book: BookConfig) -> [URL] {
        let itemsDirectory = URL(
            fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"),
            isDirectory: true
        )
        let resolvedDirectory = Self.resolvedDirectory(for: book)
        return [itemsDirectory, resolvedDirectory].flatMap { directory in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                return [] as [URL]
            }
            return files.filter { url in
                url.pathExtension.lowercased() == "md"
                    && url.lastPathComponent.caseInsensitiveCompare("README.md") != .orderedSame
            }
        }
    }

    func onDiskReviewIDs(book: BookConfig) -> Set<String> {
        Set(reviewMarkdownURLs(book: book).map { url in
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let frontmatter = parseFrontmatter(content)
                if let id = frontmatter["id"]?.nilIfBlank {
                    return id
                }
            }
            return url.deletingPathExtension().lastPathComponent
        })
    }

    func indexEntry(for url: URL, book: BookConfig, defaultStatus: String) -> ReviewIndexEntry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(content)
        let id = frontmatter["id"]?.nilIfBlank ?? url.deletingPathExtension().lastPathComponent
        let title = frontmatter["title"]?.nilIfBlank ?? firstHeading(content) ?? id
        let chapterID = value(frontmatter, keys: ["chapter_id", "chapter"])
        let status = frontmatter["status"]?.nilIfBlank ?? defaultStatus
        let createdAt = parseDate(frontmatter["created_at"])
            ?? parseDateFromFilename(url.deletingPathExtension().lastPathComponent)
            ?? url.modificationDate
        let rootPath = URL(fileURLWithPath: book.projectRootPath, isDirectory: true).standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let relativeFile: String
        if filePath.hasPrefix(rootPath + "/") {
            relativeFile = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            relativeFile = url.lastPathComponent
        }

        return ReviewIndexEntry(
            id: id,
            chapterID: chapterID,
            title: title,
            type: value(frontmatter, keys: ["type", "feedback_type"]),
            severity: frontmatter["severity"],
            status: status,
            createdAt: createdAt,
            file: relativeFile
        )
    }

    func buildIndexEntries(book: BookConfig) -> [ReviewIndexEntry] {
        let resolvedDirectory = Self.resolvedDirectory(for: book)
        var entriesByID: [String: ReviewIndexEntry] = [:]

        for url in reviewMarkdownURLs(book: book) {
            let defaultStatus = url.path.hasPrefix(resolvedDirectory.path) ? "resolved" : "open"
            guard let entry = indexEntry(for: url, book: book, defaultStatus: defaultStatus) else { continue }
            if let existing = entriesByID[entry.id] {
                let existingIsResolved = existing.file?.contains("/resolved/") == true
                let incomingIsResolved = entry.file?.contains("/resolved/") == true
                if incomingIsResolved || !existingIsResolved {
                    entriesByID[entry.id] = entry
                }
            } else {
                entriesByID[entry.id] = entry
            }
        }

        return entriesByID.values.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    static func resolvedDirectory(for book: BookConfig) -> URL {
        if let reviewsPath = book.reviewsPath?.nilIfBlank {
            return URL(fileURLWithPath: reviewsPath, isDirectory: true)
                .appendingPathComponent("resolved", isDirectory: true)
        }
        return URL(fileURLWithPath: book.suggestedPath("reviews/resolved"), isDirectory: true)
    }

    static func parseReviewStatus(_ raw: String?, inResolvedFolder: Bool, defaultStatus: ReviewStatus = .open) -> ReviewStatus {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "resolved" { return .resolved }
        if let status = ReviewStatus(rawValue: normalized), status != .unknown {
            return status
        }
        if inResolvedFolder { return .resolved }
        return defaultStatus
    }

    func reviewFileURL(id: String, book: BookConfig) -> URL? {
        let itemsURL = reviewItemsDirectory(for: book).appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: itemsURL.path) {
            return itemsURL
        }
        let resolvedURL = Self.resolvedDirectory(for: book).appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            return resolvedURL
        }
        return nil
    }
}

enum ReviewItemResolver {
    enum ResolverError: LocalizedError {
        case reviewNotFound(String)
        case alreadyOpen(String)
        case notResolved(String)
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .reviewNotFound(let id):
                return "Review not found: \(id)"
            case .alreadyOpen(let id):
                return "Review is already open: \(id)"
            case .notResolved(let id):
                return "Review is not resolved: \(id)"
            case .moveFailed(let detail):
                return detail
            }
        }
    }

    static func resolveReviewsAfterCommit(context: PendingPatchCommitContext, book: BookConfig) throws -> [String] {
        let ids = reviewIDs(from: context.evidenceFiles)
        guard !ids.isEmpty else { return [] }
        return try resolveOpenReviews(ids: ids, book: book)
    }

    static func reviewIDs(from paths: [String]) -> Set<String> {
        Set(paths.compactMap { relativePath in
            let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
            guard normalized.contains("reviews/review_items/") || normalized.contains("reviews/resolved/") else {
                return nil
            }
            return URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        })
    }

    static func resolveOpenReviews(ids: Set<String>, book: BookConfig) throws -> [String] {
        try book.withSecurityScopedProjectRoot {
            var resolvedIDs: [String] = []
            for id in ids.sorted() {
                if try resolveReview(id: id, book: book) {
                    resolvedIDs.append(id)
                }
            }
            if !resolvedIDs.isEmpty {
                try ReviewArtifactsMaintainer.repairAll(book: book)
            }
            return resolvedIDs
        }
    }

    @discardableResult
    static func resolveReview(id: String, book: BookConfig) throws -> Bool {
        let itemsDir = URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
        let sourceURL = itemsDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }

        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        let updated = updateFrontmatter(content, mutate: { fields in
            fields["status"] = "resolved"
            fields["resolved_at"] = formatTimestamp(Date())
        })

        let resolvedDir = ReviewItemParser.resolvedDirectory(for: book)
        try FileHelpers.ensureDirectory(resolvedDir.path)
        let destinationURL = resolvedDir.appendingPathComponent("\(id).md")
        try updated.write(to: destinationURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sourceURL)
        return true
    }

    static func reopenReview(id: String, book: BookConfig) throws {
        try book.withSecurityScopedProjectRoot {
            let resolvedDir = ReviewItemParser.resolvedDirectory(for: book)
            let sourceURL = resolvedDir.appendingPathComponent("\(id).md")
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                let itemsURL = URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
                    .appendingPathComponent("\(id).md")
                if FileManager.default.fileExists(atPath: itemsURL.path) {
                    throw ResolverError.alreadyOpen(id)
                }
                throw ResolverError.reviewNotFound(id)
            }

            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            let updated = updateFrontmatter(content, mutate: { fields in
                fields["status"] = "open"
                fields.removeValue(forKey: "resolved_at")
            })

            let itemsDir = URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
            try FileHelpers.ensureDirectory(itemsDir.path)
            let destinationURL = itemsDir.appendingPathComponent("\(id).md")
            try updated.write(to: destinationURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: sourceURL)
            try ReviewArtifactsMaintainer.repairAll(book: book)
        }
    }

    private static func updateFrontmatter(_ content: String, mutate: (inout [String: String]) -> Void) -> String {
        guard content.hasPrefix("---") else { return content }
        var lines = content.components(separatedBy: .newlines)
        guard let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }

        var fields: [String: String] = [:]
        var fieldOrder: [String] = []
        for line in lines[1..<endIndex] {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            fields[key] = value
            if !fieldOrder.contains(key) {
                fieldOrder.append(key)
            }
        }

        mutate(&fields)

        if fields["status"] == "resolved", !fieldOrder.contains("resolved_at"), fields["resolved_at"] != nil {
            fieldOrder.append("resolved_at")
        }
        if fields["status"] == "open" {
            fieldOrder.removeAll { $0 == "resolved_at" }
        }
        for key in fields.keys where !fieldOrder.contains(key) {
            fieldOrder.append(key)
        }

        var newFrontmatter = ["---"]
        for key in fieldOrder {
            guard let value = fields[key] else { continue }
            if key == "resolved_at" || key == "created_at" {
                newFrontmatter.append("\(key): '\(value)'")
            } else {
                newFrontmatter.append("\(key): \(yamlScalar(value))")
            }
        }
        newFrontmatter.append("---")

        let body = lines[(endIndex + 1)...].joined(separator: "\n")
        if body.isEmpty {
            return newFrontmatter.joined(separator: "\n") + "\n"
        }
        return newFrontmatter.joined(separator: "\n") + "\n" + body
    }

    private static func yamlScalar(_ value: String) -> String {
        if value.contains(":") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum ReviewIndexBuilder {
    enum BuilderError: LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let detail):
                return "Could not write review_index.json: \(detail)"
            }
        }
    }

    static func missingEntryCount(book: BookConfig, indexedIDs: Set<String>) -> Int {
        let parser = ReviewItemParser()
        return parser.onDiskReviewIDs(book: book).subtracting(indexedIDs).count
    }

    static func rebuild(book: BookConfig) throws -> ReviewIndexDocument {
        try book.withSecurityScopedProjectRoot {
            let parser = ReviewItemParser()
            let entries = parser.buildIndexEntries(book: book)
            let rebuiltAt = Date()
            try writeIndex(entries: entries, book: book, rebuiltAt: rebuiltAt)
            return ReviewIndexDocument(
                lastRebuilt: rebuiltAt,
                items: entries,
                rawJSON: try indexJSON(entries: entries, rebuiltAt: rebuiltAt)
            )
        }
    }

    static func writeIndex(entries: [ReviewIndexEntry], book: BookConfig, rebuiltAt: Date) throws {
        let outputURL = indexURL(for: book)
        try FileHelpers.ensureDirectory(outputURL.deletingLastPathComponent().path)
        let json = try indexJSON(entries: entries, rebuiltAt: rebuiltAt)
        do {
            try json.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            throw BuilderError.writeFailed(error.localizedDescription)
        }
    }

    private static func indexJSON(entries: [ReviewIndexEntry], rebuiltAt: Date) throws -> String {
        let payload: [String: Any] = [
            "last_rebuilt": formatIndexTimestamp(rebuiltAt),
            "items": entries.map(indexDictionary)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw BuilderError.writeFailed("UTF-8 encoding failed")
        }
        return json + "\n"
    }

    private static func indexURL(for book: BookConfig) -> URL {
        URL(fileURLWithPath: book.reviewsPath ?? book.suggestedPath("reviews"), isDirectory: true)
            .appendingPathComponent("review_index.json")
    }

    private static func indexDictionary(_ entry: ReviewIndexEntry) -> [String: Any] {
        var dictionary: [String: Any] = [
            "id": entry.id,
            "title": entry.title,
            "status": entry.status
        ]
        if let chapterID = entry.chapterID?.nilIfBlank {
            dictionary["chapter_id"] = chapterID
        }
        if let type = entry.type?.nilIfBlank {
            dictionary["type"] = type
        }
        if let severity = entry.severity?.nilIfBlank {
            dictionary["severity"] = severity
        }
        if let createdAt = entry.createdAt {
            dictionary["created_at"] = formatIndexTimestamp(createdAt)
        }
        if let file = entry.file?.nilIfBlank {
            dictionary["file"] = file
        }
        return dictionary
    }

    private static func formatIndexTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct ReviewArtifactsHealth: Equatable {
    var missingIndexEntries: Int
    var cumulativeStale: Bool
    var staleByChapterFiles: Int

    static let healthy = ReviewArtifactsHealth(missingIndexEntries: 0, cumulativeStale: false, staleByChapterFiles: 0)

    var needsRepair: Bool {
        missingIndexEntries > 0 || cumulativeStale || staleByChapterFiles > 0
    }

    var issueSummary: String? {
        guard needsRepair else { return nil }
        var parts: [String] = []
        if missingIndexEntries > 0 {
            parts.append("\(missingIndexEntries) missing from index")
        }
        if cumulativeStale {
            parts.append("cumulative summary out of date")
        }
        if staleByChapterFiles > 0 {
            parts.append("\(staleByChapterFiles) chapter summary file(s) out of date")
        }
        return parts.joined(separator: ", ")
    }
}

enum ReviewSummaryBuilder {
    enum BuilderError: LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let detail):
                return "Could not write review summaries: \(detail)"
            }
        }
    }

    private static let themeStopwords: Set<String> = [
        "about", "after", "also", "been", "from", "have", "that", "this", "with", "would", "should",
        "could", "their", "there", "these", "those", "what", "when", "where", "which", "while", "will",
        "your", "they", "them", "than", "then", "into", "more", "some", "such", "only", "other", "each",
        "make", "like", "just", "book", "chapter", "review", "items", "item", "open", "file", "type",
        "severity", "agent", "systems", "living"
    ]

    static func writeSummaries(
        entries: [ReviewIndexEntry],
        book: BookConfig,
        parser: ReviewItemParser,
        rebuiltAt: Date
    ) throws {
        let cumulativePath = book.cumulativeReviewPath ?? book.suggestedPath("reviews/cumulative_review.md")
        try FileHelpers.ensureDirectory(URL(fileURLWithPath: cumulativePath).deletingLastPathComponent().path)
        let cumulative = buildCumulativeReview(entries: entries, book: book, parser: parser, rebuiltAt: rebuiltAt)
        do {
            try cumulative.write(to: URL(fileURLWithPath: cumulativePath), atomically: true, encoding: .utf8)
        } catch {
            throw BuilderError.writeFailed(error.localizedDescription)
        }

        let byChapterDirectory = byChapterDirectory(for: book)
        try FileHelpers.ensureDirectory(byChapterDirectory.path)
        let grouped = Dictionary(grouping: entries.filter { $0.chapterID?.nilIfBlank != nil }) {
            $0.chapterID ?? "unknown"
        }
        var expectedFiles = Set<String>()
        for (chapterID, chapterEntries) in grouped.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            let filename = "\(chapterID).md"
            expectedFiles.insert(filename)
            let content = buildByChapterReview(chapterID: chapterID, entries: chapterEntries)
            let fileURL = byChapterDirectory.appendingPathComponent(filename)
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                throw BuilderError.writeFailed(error.localizedDescription)
            }
        }

        if let existing = try? FileManager.default.contentsOfDirectory(at: byChapterDirectory, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension.lowercased() == "md" {
                if !expectedFiles.contains(url.lastPathComponent) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    static func isCumulativeStale(content: String?, openCount: Int, resolvedCount: Int, totalEntries: Int) -> Bool {
        guard totalEntries > 0 else { return false }
        guard let content, !content.isEmpty else { return true }
        guard let parsedOpen = parseSummaryCount(in: content, label: "Total open items"),
              let parsedResolved = parseSummaryCount(in: content, label: "Total resolved items") else {
            return true
        }
        return parsedOpen != openCount || parsedResolved != resolvedCount
    }

    static func staleByChapterCount(book: BookConfig, entries: [ReviewIndexEntry]) -> Int {
        let grouped = Dictionary(grouping: entries.filter { $0.chapterID?.nilIfBlank != nil }) {
            $0.chapterID ?? "unknown"
        }
        var stale = 0
        for (chapterID, chapterEntries) in grouped {
            let fileURL = byChapterDirectory(for: book).appendingPathComponent("\(chapterID).md")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                stale += 1
                continue
            }
            let openCount = chapterEntries.filter { $0.status.lowercased() == "open" }.count
            let resolvedCount = chapterEntries.filter { $0.status.lowercased() == "resolved" }.count
            guard let parsedOpen = parseInlineCount(in: content, label: "Open"),
                  let parsedResolved = parseInlineCount(in: content, label: "Resolved") else {
                stale += 1
                continue
            }
            if parsedOpen != openCount || parsedResolved != resolvedCount {
                stale += 1
            }
        }
        return stale
    }

    private static func buildCumulativeReview(
        entries: [ReviewIndexEntry],
        book: BookConfig,
        parser: ReviewItemParser,
        rebuiltAt: Date
    ) -> String {
        let openEntries = entries.filter { $0.status.lowercased() == "open" }
        let resolvedEntries = entries.filter { $0.status.lowercased() == "resolved" }
        let criticalCount = openEntries.filter { $0.severity?.lowercased() == FeedbackSeverity.critical.rawValue }.count
        let highCount = openEntries.filter { $0.severity?.lowercased() == FeedbackSeverity.high.rawValue }.count
        let rebuiltLabel = DateFormatting.cumulativeReview.string(from: rebuiltAt)

        var lines = [
            "# Cumulative Review",
            "",
            "Last rebuilt: \(rebuiltLabel)",
            "",
            "## Summary",
            "",
            "Total open items: \(openEntries.count)  ",
            "Total resolved items: \(resolvedEntries.count)  ",
            "Critical items: \(criticalCount)  ",
            "High priority items: \(highCount)  ",
            ""
        ]

        lines.append("## Open Items by Chapter")
        lines.append("")
        if openEntries.isEmpty {
            lines.append("_No open review items._")
            lines.append("")
        } else {
            let grouped = Dictionary(grouping: openEntries) { $0.chapterID ?? "unknown" }
            for chapterID in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let chapterEntries = grouped[chapterID] ?? []
                let displayName = chapterDisplayName(chapterID: chapterID, entries: chapterEntries)
                lines.append("### \(chapterID) — \(displayName)")
                lines.append("")
                for entry in chapterEntries.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }) {
                    lines.append("- [ ] \(entry.title)  ")
                    if let type = entry.type?.nilIfBlank {
                        lines.append("  Type: \(type)  ")
                    }
                    if let severity = entry.severity?.nilIfBlank {
                        lines.append("  Severity: \(severity)  ")
                    }
                    if let file = entry.file?.nilIfBlank {
                        lines.append("  File: \(file)")
                    }
                    lines.append("")
                }
            }
        }

        lines.append("## Themes Across Feedback")
        lines.append("")
        let themes = extractThemes(from: openEntries, book: book, parser: parser)
        if themes.isEmpty {
            lines.append("_No recurring themes detected in open reviews._")
        } else {
            for theme in themes {
                lines.append("- Recurring theme around \"\(theme.word)\" (\(theme.count) mentions in open reviews).")
            }
        }
        lines.append("")
        lines.append("## Suggested Revision Priorities")
        lines.append("")
        let priorities = openEntries.sorted { lhs, rhs in
            let left = FeedbackSeverity(rawValue: lhs.severity ?? "")?.rank ?? 99
            let right = FeedbackSeverity(rawValue: rhs.severity ?? "")?.rank ?? 99
            if left != right { return left < right }
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
        if priorities.isEmpty {
            lines.append("_No open review items to prioritize._")
        } else {
            for (index, entry) in priorities.enumerated() {
                let chapter = entry.chapterID ?? "unknown"
                let severity = entry.severity ?? "unknown"
                let type = entry.type ?? "feedback"
                lines.append("\(index + 1). Address \"\(entry.title)\" in \(chapter) (\(severity) / \(type)).")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func buildByChapterReview(chapterID: String, entries: [ReviewIndexEntry]) -> String {
        let openEntries = entries.filter { $0.status.lowercased() == "open" }
        let resolvedEntries = entries.filter { $0.status.lowercased() == "resolved" }
        let displayName = chapterDisplayName(chapterID: chapterID, entries: entries)
        var lines = [
            "# Reviews — \(displayName)",
            "",
            "Chapter ID: `\(chapterID)`",
            "",
            "Open: \(openEntries.count) | Resolved: \(resolvedEntries.count)",
            "",
            "## Open Items",
            ""
        ]

        if openEntries.isEmpty {
            lines.append("_None._")
        } else {
            for entry in openEntries.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }) {
                let severity = entry.severity ?? "unknown"
                let type = entry.type ?? "feedback"
                lines.append("- **\(entry.title)** (\(severity) / \(type))")
                if let file = entry.file?.nilIfBlank {
                    lines.append("  - File: `\(file)`")
                }
                lines.append("")
            }
        }

        lines.append("## Resolved Items")
        lines.append("")
        if resolvedEntries.isEmpty {
            lines.append("_None._")
        } else {
            for entry in resolvedEntries.sorted(by: { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }) {
                let file = entry.file ?? entry.id
                lines.append("- \(entry.title) — `\(file)`")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func chapterDisplayName(chapterID: String, entries: [ReviewIndexEntry]) -> String {
        if let title = entries.compactMap(\.title).first(where: { !$0.isEmpty }) {
            if let range = title.range(of: " - LLM") {
                return String(title[..<range.lowerBound])
            }
            if let range = title.range(of: " - ") {
                return String(title[..<range.lowerBound])
            }
            return title
        }
        return chapterID
            .split(separator: "-")
            .map { part in
                part.count <= 3 ? part.uppercased() : part.capitalized
            }
            .joined(separator: " ")
    }

    private static func extractThemes(
        from entries: [ReviewIndexEntry],
        book: BookConfig,
        parser: ReviewItemParser
    ) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let text = reviewBody(for: entry, book: book, parser: parser) ?? entry.title
            let words = text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && !themeStopwords.contains($0) }
            for word in words {
                counts[word, default: 0] += 1
            }
        }
        return counts
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
            .prefix(5)
            .map { (word: $0.key, count: $0.value) }
    }

    private static func reviewBody(for entry: ReviewIndexEntry, book: BookConfig, parser: ReviewItemParser) -> String? {
        guard let file = entry.file?.nilIfBlank else { return nil }
        let absolute = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(file)
            .path
        guard FileManager.default.fileExists(atPath: absolute),
              let content = try? String(contentsOfFile: absolute, encoding: .utf8) else {
            return nil
        }
        return parser.conversationSection(from: content) ?? content
    }

    private static func parseSummaryCount(in content: String, label: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "(?m)^\(escaped):\\s*(\\d+)\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content),
              let value = Int(content[range]) else {
            return nil
        }
        return value
    }

    private static func parseInlineCount(in content: String, label: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "\(escaped):\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content),
              let value = Int(content[range]) else {
            return nil
        }
        return value
    }

    private static func byChapterDirectory(for book: BookConfig) -> URL {
        URL(fileURLWithPath: book.reviewsPath ?? book.suggestedPath("reviews"), isDirectory: true)
            .appendingPathComponent("by_chapter", isDirectory: true)
    }
}

enum ReviewArtifactsMaintainer {
    static let maintenanceInterval: TimeInterval = 5 * 60

    static func assessHealth(
        book: BookConfig,
        indexDocument: ReviewIndexDocument?,
        cumulativeReview: String?
    ) -> ReviewArtifactsHealth {
        let parser = ReviewItemParser()
        let entries = parser.buildIndexEntries(book: book)
        let indexedIDs = Set((indexDocument?.items ?? []).map(\.id))
        let missingIndexEntries = ReviewIndexBuilder.missingEntryCount(book: book, indexedIDs: indexedIDs)
        let openCount = entries.filter { $0.status.lowercased() == "open" }.count
        let resolvedCount = entries.filter { $0.status.lowercased() == "resolved" }.count
        let cumulativeStale = ReviewSummaryBuilder.isCumulativeStale(
            content: cumulativeReview,
            openCount: openCount,
            resolvedCount: resolvedCount,
            totalEntries: entries.count
        )
        let staleByChapterFiles = ReviewSummaryBuilder.staleByChapterCount(book: book, entries: entries)
        return ReviewArtifactsHealth(
            missingIndexEntries: missingIndexEntries,
            cumulativeStale: cumulativeStale,
            staleByChapterFiles: staleByChapterFiles
        )
    }

    @discardableResult
    static func repairIfNeeded(book: BookConfig) throws -> Bool {
        let cumulative = ReviewItemParser().readOptional(path: book.cumulativeReviewPath)
        let indexDocument = try ReviewIndexParser().parse(book: book)
        let health = assessHealth(book: book, indexDocument: indexDocument, cumulativeReview: cumulative)
        guard health.needsRepair else { return false }
        try repairAll(book: book)
        return true
    }

    static func repairAll(book: BookConfig) throws {
        try book.withSecurityScopedProjectRoot {
            let parser = ReviewItemParser()
            let entries = parser.buildIndexEntries(book: book)
            let rebuiltAt = Date()
            try ReviewIndexBuilder.writeIndex(entries: entries, book: book, rebuiltAt: rebuiltAt)
            try ReviewSummaryBuilder.writeSummaries(entries: entries, book: book, parser: parser, rebuiltAt: rebuiltAt)
        }
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
            title = "Validate the book and report issues."
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
            modeInstruction(mode, book: book),
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
            lines.append(contentsOf: figureRequirements(chapterID: chapterID, reviewItems: reviewItems, book: book))
        }

        if mode == .validateBook {
            lines.append(contentsOf: validationRequirements(book: book))
        }

        var constraints: [String] = [
            "- Preserve chapter voice.",
            "- Add concrete examples where useful.",
            "- Do not introduce unsupported benchmark claims.",
            "- Do not rewrite the whole chapter unless necessary.",
            "- Return a unified diff.",
        ]
        if let validationLine = validationConstraintLine(book: book) {
            constraints.append(validationLine)
        }
        constraints.append(contentsOf: [
            "- If a figure is needed, generate a script-based figure rather than only a static image.",
            "- Do not directly apply changes; BookLoop must review the patch first.",
            "",
            "## Expected Output",
            "- Revision summary",
            "- Files changed",
            "- Unified patch",
            "- Link scan / validation result",
            "- Review items addressed",
            "- Review items not addressed and why"
        ])

        lines.append(contentsOf: [""] + ["## Constraints"] + constraints)

        return lines.joined(separator: "\n") + "\n"
    }

    private func modeInstruction(_ mode: RevisionTaskMode, book: BookConfig) -> String {
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
            if book.effectiveValidationCommand != nil {
                return "Run the configured validation command and report issues. Do not directly modify files."
            }
            return "Use scan_broken_links and review checks to validate the book. Do not run mkdocs or other external build tools. Do not directly modify files."
        }
    }

    private func figureRequirements(chapterID: String?, reviewItems: [ReviewItem], book: BookConfig) -> [String] {
        var lines = [
            "",
            "## Figure Requirements",
            "- Use a reproducible source script.",
            "- Prefer Python matplotlib, SVG, Mermaid, Graphviz, or TikZ.",
            "- Do not produce only an untraceable PNG.",
            "- Save source under `figures/<figure-id>/`.",
            "- Save final asset under `docs/assets/figures/`.",
            "- Add alt text and caption.",
            "- Insert figure into the chapter only through a visible patch.",
        ]
        if let validationLine = validationConstraintLine(book: book) {
            lines.append(validationLine)
        }
        return lines
    }

    private func validationRequirements(book: BookConfig) -> [String] {
        var lines = [
            "",
            "## Validation Checklist",
        ]
        if book.effectiveValidationCommand != nil {
            lines.append("- Run the configured validation command if possible.")
        } else {
            lines.append("- Use scan_broken_links to find missing figures and broken local asset links.")
            lines.append("- Do not run mkdocs or assume an external site generator is installed.")
        }
        lines.append(contentsOf: [
            "- Check image references.",
            "- Check broken internal links.",
            "- Check stale figures.",
            "- Check missing captions or alt text.",
            "- Summarize open review items by severity."
        ])
        return lines
    }

    private func validationConstraintLine(book: BookConfig) -> String? {
        if book.effectiveValidationCommand != nil {
            return "- Run the configured validation command if possible."
        }
        return "- Use scan_broken_links for link and asset validation; BookLoop preview does not require mkdocs."
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

struct BrokenLinkIssue: Codable, Equatable {
    enum Kind: String, Codable {
        case missingFigure
        case staleFigure
        case brokenLocalLink
        case externalAssetLink
    }

    var kind: Kind
    var markdownFile: String
    var line: Int
    var reference: String
    var resolvedPath: String?
    var message: String
}

struct BrokenLinkScanResult: Codable, Equatable {
    var issueCount: Int
    var issues: [BrokenLinkIssue]
    var summary: String
}

final class BrokenLinkScanner {
    private static let assetExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "webp", "mp4", "mov", "webm"
    ]

    private static let markdownLinkRegex = try? NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\(([^)]+)\)"#
    )

    func scan(book: BookConfig) throws -> BrokenLinkScanResult {
        var issues: [BrokenLinkIssue] = []
        var seen = Set<String>()

        let figures = try FigureScanner().scan(book: book)
        for figure in figures {
            switch figure.status {
            case .missingOutput:
                appendFigureIssues(
                    figure: figure,
                    kind: .missingFigure,
                    message: "Referenced figure file is missing on disk.",
                    issues: &issues,
                    seen: &seen,
                    book: book
                )
            case .stale:
                appendFigureIssues(
                    figure: figure,
                    kind: .staleFigure,
                    message: "Figure output is older than its source script.",
                    issues: &issues,
                    seen: &seen,
                    book: book
                )
            default:
                break
            }
        }

        issues.append(contentsOf: scanMarkdownLinks(book: book, seen: &seen))
        let sorted = issues.sorted {
            if $0.markdownFile != $1.markdownFile {
                return $0.markdownFile.localizedStandardCompare($1.markdownFile) == .orderedAscending
            }
            if $0.line != $1.line {
                return $0.line < $1.line
            }
            return $0.reference.localizedStandardCompare($1.reference) == .orderedAscending
        }

        let summary: String
        if sorted.isEmpty {
            summary = "No broken figure paths or local asset links found."
        } else {
            let missing = sorted.filter { $0.kind == .missingFigure }.count
            let broken = sorted.filter { $0.kind == .brokenLocalLink }.count
            let external = sorted.filter { $0.kind == .externalAssetLink }.count
            let stale = sorted.filter { $0.kind == .staleFigure }.count
            summary = "Found \(sorted.count) issue(s): \(missing) missing figure(s), \(broken) broken local link(s), \(external) external asset URL(s), \(stale) stale figure(s)."
        }

        return BrokenLinkScanResult(issueCount: sorted.count, issues: sorted, summary: summary)
    }

    private func appendFigureIssues(
        figure: FigureItem,
        kind: BrokenLinkIssue.Kind,
        message: String,
        issues: inout [BrokenLinkIssue],
        seen: inout Set<String>,
        book: BookConfig
    ) {
        let resolved = relativePath(for: figure.outputPath, book: book)
        let references = figure.referencedFrom.isEmpty ? [""] : figure.referencedFrom
        for markdownPath in references {
            let markdownFile = markdownPath.isEmpty ? "unknown" : relativePath(for: markdownPath, book: book)
            let key = "\(kind.rawValue)|\(markdownFile)|\(resolved)"
            guard seen.insert(key).inserted else { continue }
            issues.append(BrokenLinkIssue(
                kind: kind,
                markdownFile: markdownFile,
                line: 0,
                reference: resolved,
                resolvedPath: resolved,
                message: message
            ))
        }
    }

    private func scanMarkdownLinks(book: BookConfig, seen: inout Set<String>) -> [BrokenLinkIssue] {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
              let regex = Self.markdownLinkRegex else { return [] }

        var issues: [BrokenLinkIssue] = []
        for case let markdownURL as URL in enumerator where markdownURL.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: markdownURL, encoding: .utf8) else { continue }
            let markdownFile = relativePath(for: markdownURL.path, book: book)
            let ns = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))

            for match in matches where match.numberOfRanges >= 4 {
                let isImage = !ns.substring(with: match.range(at: 1)).isEmpty
                let rawTarget = ns.substring(with: match.range(at: 3))
                let target = cleanedTarget(rawTarget)
                guard !target.isEmpty else { continue }

                let line = lineNumber(in: content, range: match.range)
                if let issue = issue(
                    for: target,
                    isImage: isImage,
                    markdownFile: markdownFile,
                    markdownPath: markdownURL.path,
                    line: line,
                    book: book
                ) {
                    let key = "\(issue.kind.rawValue)|\(issue.markdownFile)|\(issue.line)|\(issue.reference)"
                    if seen.insert(key).inserted {
                        issues.append(issue)
                    }
                }
            }
        }
        return issues
    }

    private func issue(
        for target: String,
        isImage: Bool,
        markdownFile: String,
        markdownPath: String,
        line: Int,
        book: BookConfig
    ) -> BrokenLinkIssue? {
        let lowered = target.lowercased()
        if lowered.hasPrefix("mailto:") { return nil }
        if target.hasPrefix("#") { return nil }

        let pathPart = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        if pathPart.isEmpty { return nil }

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard isImage || isAssetReference(pathPart) else { return nil }
            return BrokenLinkIssue(
                kind: .externalAssetLink,
                markdownFile: markdownFile,
                line: line,
                reference: target,
                resolvedPath: nil,
                message: "External asset URL — verify with fetch_url before changing."
            )
        }

        let resolved = resolve(pathPart, fromMarkdown: markdownPath, book: book)
        let resolvedRelative = relativePath(for: resolved, book: book)
        guard !FileManager.default.fileExists(atPath: resolved) else { return nil }

        let message = isImage
            ? "Image reference points to a missing local file."
            : "Markdown link points to a missing local file."
        return BrokenLinkIssue(
            kind: .brokenLocalLink,
            markdownFile: markdownFile,
            line: line,
            reference: target,
            resolvedPath: resolvedRelative,
            message: message
        )
    }

    private func cleanedTarget(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            .components(separatedBy: " ").first ?? ""
    }

    private func isAssetReference(_ value: String) -> Bool {
        let ext = URL(string: value)?.pathExtension.lowercased()
            ?? URL(fileURLWithPath: value).pathExtension.lowercased()
        return Self.assetExtensions.contains(ext)
    }

    private func lineNumber(in content: String, range: NSRange) -> Int {
        let prefix = (content as NSString).substring(to: range.location)
        return prefix.components(separatedBy: "\n").count
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

    private func relativePath(for absolutePath: String, book: BookConfig) -> String {
        let root = URL(fileURLWithPath: book.projectRootPath, isDirectory: true).standardizedFileURL.path
        let absolute = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        if absolute.hasPrefix(root + "/") {
            return String(absolute.dropFirst(root.count + 1))
        }
        return absolutePath
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

enum ReviewItemMarkdownLoader {
    static func bodyMarkdown(for item: ReviewItem) -> String {
        if let content = try? String(contentsOfFile: item.filePath, encoding: .utf8) {
            let stripped = stripFrontmatter(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return fallbackMarkdown(for: item)
    }

    private static func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: .newlines)
        guard let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }
        return lines[(endIndex + 1)...].joined(separator: "\n")
    }

    private static func fallbackMarkdown(for item: ReviewItem) -> String {
        var parts = ["# \(item.title)", ""]
        if let body = item.body?.nilIfBlank {
            parts.append(body)
        }
        if let fix = item.suggestedFix?.nilIfBlank {
            parts.append("")
            parts.append("## Suggested Fix")
            parts.append("")
            parts.append(fix)
        }
        return parts.joined(separator: "\n")
    }
}

final class ReviewItemMarkdownRenderer {
    func renderDocument(markdown: String, title: String? = nil) -> String {
        let body = renderBody(markdown)
        let safeTitle = escapeHTML(title ?? "Review Item")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="color-scheme" content="light dark">
          <style>
            :root {
              color-scheme: light dark;
              --accent: #007aff;
              --user-accent: #5856d6;
              --assistant-accent: #34c759;
              --surface: rgba(127, 127, 127, 0.08);
              --border: rgba(127, 127, 127, 0.22);
              --muted: #636366;
            }
            body {
              font: -apple-system-body;
              margin: 0;
              padding: 16px 18px 24px;
              line-height: 1.55;
              color: CanvasText;
              background: Canvas;
            }
            h1, h2, h3, h4 { margin: 0.85em 0 0.4em; line-height: 1.25; }
            h1 { font-size: 1.35rem; margin-top: 0; }
            h2 { font-size: 1.1rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.03em; }
            h3 { font-size: 1rem; }
            p { margin: 0.5em 0; }
            blockquote {
              border-left: 3px solid var(--muted);
              color: var(--muted);
              margin: 0.65em 0;
              padding: 0.15em 0 0.15em 0.85em;
            }
            pre {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 8px;
              overflow-x: auto;
              padding: 10px 12px;
            }
            code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: 0.92em;
            }
            p code, li code {
              background: var(--surface);
              border-radius: 4px;
              padding: 1px 5px;
            }
            ul, ol { padding-left: 1.35em; margin: 0.45em 0; }
            .speaker-block {
              margin: 12px 0;
              padding: 10px 12px 10px 14px;
              border-radius: 10px;
              border: 1px solid var(--border);
              background: var(--surface);
            }
            .speaker-block.user { border-left: 3px solid var(--user-accent); }
            .speaker-block.assistant { border-left: 3px solid var(--assistant-accent); }
            .speaker-label {
              font-size: 0.72rem;
              font-weight: 700;
              letter-spacing: 0.06em;
              text-transform: uppercase;
              color: var(--muted);
              margin-bottom: 6px;
            }
            .speaker-block.user .speaker-label { color: var(--user-accent); }
            .speaker-block.assistant .speaker-label { color: var(--assistant-accent); }
            .empty { color: var(--muted); font-style: italic; }
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
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                html.append(renderCodeBlock(lines: lines, startIndex: &index))
                continue
            }

            if let speaker = speakerLabel(for: trimmed) {
                html.append(renderSpeakerBlock(label: speaker, lines: lines, startIndex: &index))
                continue
            }

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let heading = headingHTML(for: trimmed) {
                html.append(heading)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                html.append("<blockquote>\(renderInline(String(quote)))</blockquote>")
                index += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                html.append(renderList(lines: lines, startIndex: &index, ordered: false))
                continue
            }

            if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                html.append(renderList(lines: lines, startIndex: &index, ordered: true))
                continue
            }

            var paragraphLines = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix(">")
                    || next.hasPrefix("- ") || next.hasPrefix("* ")
                    || speakerLabel(for: next) != nil
                    || next.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }
            html.append("<p>\(renderInline(paragraphLines.joined(separator: " ")))</p>")
        }

        if html.isEmpty {
            return "<p class=\"empty\">No review content.</p>"
        }
        return html.joined(separator: "\n")
    }

    private func speakerLabel(for line: String) -> String? {
        guard line.hasPrefix("### ") else { return nil }
        let label = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()
        if label == "user" || label == "assistant" {
            return label
        }
        return nil
    }

    private func renderSpeakerBlock(label: String, lines: [String], startIndex: inout Int) -> String {
        startIndex += 1
        var blockLines: [String] = []
        while startIndex < lines.count {
            let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") {
                break
            }
            if trimmed.isEmpty && !blockLines.isEmpty {
                let nextIndex = startIndex + 1
                if nextIndex < lines.count {
                    let next = lines[nextIndex].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("### ") || next.hasPrefix("## ") {
                        break
                    }
                }
            }
            blockLines.append(lines[startIndex])
            startIndex += 1
        }

        let innerMarkdown = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let innerHTML = innerMarkdown.isEmpty ? "<p class=\"empty\">No content.</p>" : renderBody(innerMarkdown)
        let displayLabel = label.capitalized
        return """
        <section class="speaker-block \(label)">
          <div class="speaker-label">\(displayLabel)</div>
          \(innerHTML)
        </section>
        """
    }

    private func renderCodeBlock(lines: [String], startIndex: inout Int) -> String {
        startIndex += 1
        var codeLines: [String] = []
        while startIndex < lines.count {
            let line = lines[startIndex]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                startIndex += 1
                break
            }
            codeLines.append(line)
            startIndex += 1
        }
        return "<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>"
    }

    private func renderList(lines: [String], startIndex: inout Int, ordered: Bool) -> String {
        var items: [String] = []
        let itemPattern = ordered ? #"^\d+\.\s"# : #"^[-*]\s"#
        while startIndex < lines.count {
            let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: itemPattern, options: .regularExpression) != nil else { break }
            let content = ordered
                ? trimmed.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression)
                : String(trimmed.dropFirst(2))
            items.append("<li>\(renderInline(content))</li>")
            startIndex += 1
        }
        let tag = ordered ? "ol" : "ul"
        return "<\(tag)>\(items.joined())</\(tag)>"
    }

    private func headingHTML(for line: String) -> String? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...4).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level + 1)
        return "<h\(level)>\(renderInline(String(text)))</h\(level)>"
    }

    private func renderInline(_ markdown: String) -> String {
        var text = escapeHTML(markdown)
        text = text.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        return text
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

final class ReviewSummaryMarkdownRenderer {
    func renderDocument(markdown: String) -> String {
        let body = renderBody(markdown)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="color-scheme" content="light dark">
          <style>
            :root {
              color-scheme: light dark;
              --accent: #007aff;
              --accent-soft: rgba(0, 122, 255, 0.12);
              --surface: rgba(127, 127, 127, 0.08);
              --surface-strong: rgba(127, 127, 127, 0.14);
              --border: rgba(127, 127, 127, 0.22);
              --muted: #636366;
              --open: #ff9500;
              --resolved: #34c759;
              --critical: #ff3b30;
              --high: #ff9500;
            }
            body {
              font: -apple-system-body;
              margin: 0;
              padding: 20px 22px 28px;
              line-height: 1.5;
              color: CanvasText;
              background: Canvas;
            }
            .doc-header {
              margin-bottom: 22px;
              padding-bottom: 16px;
              border-bottom: 1px solid var(--border);
            }
            .doc-header h1 {
              margin: 0 0 8px;
              font-size: 1.65rem;
              font-weight: 700;
              letter-spacing: -0.02em;
            }
            .rebuilt-badge {
              display: inline-block;
              font-size: 0.82rem;
              color: var(--muted);
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 999px;
              padding: 4px 10px;
            }
            .section {
              margin: 26px 0 0;
            }
            .section h2 {
              margin: 0 0 14px;
              font-size: 1.05rem;
              font-weight: 600;
              letter-spacing: -0.01em;
              text-transform: uppercase;
              color: var(--muted);
            }
            .stats-grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
              gap: 10px;
            }
            .stat-card {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 12px 14px;
            }
            .stat-card .label {
              display: block;
              font-size: 0.78rem;
              color: var(--muted);
              margin-bottom: 4px;
            }
            .stat-card .value {
              font-size: 1.55rem;
              font-weight: 700;
              letter-spacing: -0.03em;
            }
            .stat-card.open .value { color: var(--open); }
            .stat-card.resolved .value { color: var(--resolved); }
            .stat-card.critical .value { color: var(--critical); }
            .stat-card.high .value { color: var(--high); }
            .chapter-card {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 14px;
              padding: 14px 16px;
              margin-bottom: 12px;
            }
            .chapter-card h3 {
              margin: 0 0 12px;
              font-size: 1rem;
              font-weight: 600;
              line-height: 1.35;
            }
            .chapter-id {
              display: block;
              font-size: 0.78rem;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              color: var(--muted);
              margin-top: 2px;
            }
            .review-item {
              list-style: none;
              margin: 0 0 10px;
              padding: 10px 12px;
              background: Canvas;
              border: 1px solid var(--border);
              border-radius: 10px;
            }
            .review-item:last-child { margin-bottom: 0; }
            .review-title-row {
              display: flex;
              align-items: flex-start;
              gap: 8px;
              margin-bottom: 8px;
            }
            .checkbox {
              flex: 0 0 auto;
              width: 16px;
              height: 16px;
              border: 1.5px solid var(--border);
              border-radius: 4px;
              margin-top: 2px;
            }
            .review-title {
              font-weight: 600;
              line-height: 1.35;
            }
            .meta-row {
              display: flex;
              flex-wrap: wrap;
              gap: 6px;
              margin-left: 24px;
            }
            .meta-pill {
              font-size: 0.74rem;
              padding: 2px 8px;
              border-radius: 999px;
              background: var(--surface-strong);
              color: var(--muted);
            }
            .meta-pill.type { color: var(--accent); background: var(--accent-soft); }
            .meta-pill.severity-medium { color: #bf5f00; background: rgba(255, 149, 0, 0.14); }
            .meta-pill.severity-high { color: var(--high); background: rgba(255, 149, 0, 0.16); }
            .meta-pill.severity-critical { color: var(--critical); background: rgba(255, 59, 48, 0.14); }
            .meta-pill.severity-low { color: #248a3d; background: rgba(52, 199, 89, 0.14); }
            .file-path {
              display: block;
              margin: 6px 0 0 24px;
              font-size: 0.76rem;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              color: var(--muted);
              word-break: break-all;
            }
            .theme-list, .priority-list, .plain-list {
              margin: 0;
              padding: 0;
              list-style: none;
            }
            .theme-item {
              padding: 10px 12px 10px 14px;
              margin-bottom: 8px;
              border-left: 3px solid var(--accent);
              background: var(--surface);
              border-radius: 0 10px 10px 0;
            }
            .priority-item {
              display: flex;
              gap: 10px;
              align-items: flex-start;
              padding: 10px 0;
              border-bottom: 1px solid var(--border);
            }
            .priority-item:last-child { border-bottom: none; }
            .priority-rank {
              flex: 0 0 auto;
              width: 24px;
              height: 24px;
              border-radius: 50%;
              background: var(--accent-soft);
              color: var(--accent);
              font-size: 0.78rem;
              font-weight: 700;
              display: flex;
              align-items: center;
              justify-content: center;
            }
            .plain-item {
              padding: 6px 0;
              color: var(--muted);
            }
            .empty-note {
              color: var(--muted);
              font-style: italic;
              margin: 0;
            }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func renderBody(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var html: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                html.append(renderDocumentHeader(title: String(trimmed.dropFirst(2)), lines: lines, startIndex: &index))
                continue
            }

            if trimmed.hasPrefix("## ") {
                let sectionTitle = String(trimmed.dropFirst(3))
                index += 1
                html.append(renderSection(title: sectionTitle, lines: lines, startIndex: &index))
                continue
            }

            if trimmed.hasPrefix("### ") {
                html.append(renderChapterBlock(titleLine: trimmed, lines: lines, startIndex: &index))
                continue
            }

            if !trimmed.isEmpty {
                html.append("<p>\(escapeHTML(trimmed))</p>")
            }
            index += 1
        }

        return html.joined(separator: "\n")
    }

    private func renderDocumentHeader(title: String, lines: [String], startIndex: inout Int) -> String {
        startIndex += 1
        var rebuilt: String?
        if startIndex < lines.count {
            let next = lines[startIndex].trimmingCharacters(in: .whitespaces)
            if next.lowercased().hasPrefix("last rebuilt:") {
                rebuilt = String(next.dropFirst("last rebuilt:".count)).trimmingCharacters(in: .whitespaces)
                startIndex += 1
            }
        }
        var parts = [
            "<header class=\"doc-header\">",
            "<h1>\(escapeHTML(title))</h1>"
        ]
        if let rebuilt, !rebuilt.isEmpty {
            parts.append("<span class=\"rebuilt-badge\">Last rebuilt: \(escapeHTML(rebuilt))</span>")
        }
        parts.append("</header>")
        return parts.joined(separator: "\n")
    }

    private func renderSection(title: String, lines: [String], startIndex: inout Int) -> String {
        var sectionLines: [String] = []
        while startIndex < lines.count {
            let trimmed = lines[startIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            sectionLines.append(lines[startIndex])
            startIndex += 1
        }

        let content: String
        switch title.lowercased() {
        case "summary":
            content = renderSummarySection(sectionLines)
        case "open items by chapter":
            content = renderOpenItemsSection(sectionLines)
        case "themes across feedback":
            content = renderThemesSection(sectionLines)
        case "suggested revision priorities":
            content = renderPrioritiesSection(sectionLines)
        default:
            content = renderGenericSection(sectionLines)
        }

        return """
        <section class="section">
          <h2>\(escapeHTML(title))</h2>
          \(content)
        </section>
        """
    }

    private func renderSummarySection(_ lines: [String]) -> String {
        var cards: [String] = []
        let statPattern = #"^Total (.+):\s*(\d+)\s*$"#
        let regex = try? NSRegularExpression(pattern: statPattern)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let ns = trimmed as NSString
            guard let regex,
                  let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: trimmed),
                  let valueRange = Range(match.range(at: 2), in: trimmed) else {
                continue
            }
            let label = String(trimmed[labelRange])
            let value = String(trimmed[valueRange])
            let cssClass = summaryCardClass(for: label)
            cards.append("""
            <div class="stat-card \(cssClass)">
              <span class="label">\(escapeHTML(label))</span>
              <span class="value">\(escapeHTML(value))</span>
            </div>
            """)
        }

        if cards.isEmpty {
            return "<p class=\"empty-note\">No summary statistics available.</p>"
        }
        return "<div class=\"stats-grid\">\(cards.joined())</div>"
    }

    private func summaryCardClass(for label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("open") { return "open" }
        if lower.contains("resolved") { return "resolved" }
        if lower.contains("critical") { return "critical" }
        if lower.contains("high") { return "high" }
        return ""
    }

    private func renderOpenItemsSection(_ lines: [String]) -> String {
        var html: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                html.append(renderChapterBlock(titleLine: trimmed, lines: lines, startIndex: &index))
            } else if trimmed.hasPrefix("_") && trimmed.hasSuffix("_") {
                html.append("<p class=\"empty-note\">\(escapeHTML(String(trimmed.dropFirst().dropLast())))</p>")
                index += 1
            } else if !trimmed.isEmpty {
                index += 1
            } else {
                index += 1
            }
        }
        if html.isEmpty {
            return "<p class=\"empty-note\">No open review items.</p>"
        }
        return html.joined()
    }

    private func renderChapterBlock(titleLine: String, lines: [String], startIndex: inout Int) -> String {
        let heading = String(titleLine.dropFirst(4))
        let parts = heading.components(separatedBy: " — ")
        let chapterID = parts.first ?? heading
        let chapterTitle = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : chapterID
        startIndex += 1

        var items: [String] = []
        while startIndex < lines.count {
            let line = lines[startIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") { break }
            if trimmed.isEmpty {
                startIndex += 1
                continue
            }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                items.append(renderReviewItem(line: line, lines: lines, startIndex: &startIndex))
            } else {
                startIndex += 1
            }
        }

        let itemsHTML = items.isEmpty
            ? "<p class=\"empty-note\">No items for this chapter.</p>"
            : "<ul class=\"plain-list\">\(items.joined())</ul>"

        return """
        <article class="chapter-card">
          <h3>\(escapeHTML(chapterTitle))<span class="chapter-id">\(escapeHTML(chapterID))</span></h3>
          \(itemsHTML)
        </article>
        """
    }

    private func renderReviewItem(line: String, lines: [String], startIndex: inout Int) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let title = trimmed
            .replacingOccurrences(of: "- [ ]", with: "")
            .replacingOccurrences(of: "- [x]", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        startIndex += 1

        var type: String?
        var severity: String?
        var file: String?

        while startIndex < lines.count {
            let metaLine = lines[startIndex]
            let metaTrimmed = metaLine.trimmingCharacters(in: .whitespaces)
            if metaTrimmed.hasPrefix("- [") || metaTrimmed.hasPrefix("## ") || metaTrimmed.hasPrefix("### ") {
                break
            }
            if metaLine.hasPrefix("  ") || metaLine.hasPrefix("\t") {
                if metaTrimmed.lowercased().hasPrefix("type:") {
                    type = String(metaTrimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else if metaTrimmed.lowercased().hasPrefix("severity:") {
                    severity = String(metaTrimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                } else if metaTrimmed.lowercased().hasPrefix("file:") {
                    file = String(metaTrimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                startIndex += 1
            } else if metaTrimmed.isEmpty {
                startIndex += 1
            } else {
                break
            }
        }

        var pills: [String] = []
        if let type, !type.isEmpty {
            pills.append("<span class=\"meta-pill type\">\(escapeHTML(type))</span>")
        }
        if let severity, !severity.isEmpty {
            let css = "severity-\(severity.lowercased())"
            pills.append("<span class=\"meta-pill \(css)\">\(escapeHTML(severity))</span>")
        }

        var parts = [
            "<li class=\"review-item\">",
            "<div class=\"review-title-row\"><span class=\"checkbox\"></span><span class=\"review-title\">\(escapeHTML(title))</span></div>"
        ]
        if !pills.isEmpty {
            parts.append("<div class=\"meta-row\">\(pills.joined())</div>")
        }
        if let file, !file.isEmpty {
            parts.append("<span class=\"file-path\">\(escapeHTML(file))</span>")
        }
        parts.append("</li>")
        return parts.joined()
    }

    private func renderThemesSection(_ lines: [String]) -> String {
        var items: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                items.append("<li class=\"theme-item\">\(escapeHTML(String(trimmed.dropFirst(2))))</li>")
            } else if trimmed.hasPrefix("_") && trimmed.hasSuffix("_") {
                return "<p class=\"empty-note\">\(escapeHTML(String(trimmed.dropFirst().dropLast())))</p>"
            }
        }
        if items.isEmpty {
            return "<p class=\"empty-note\">No recurring themes detected.</p>"
        }
        return "<ul class=\"theme-list\">\(items.joined())</ul>"
    }

    private func renderPrioritiesSection(_ lines: [String]) -> String {
        var items: [String] = []
        let pattern = #"^(\d+)\.\s*(.+)$"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("_") && trimmed.hasSuffix("_") {
                return "<p class=\"empty-note\">\(escapeHTML(String(trimmed.dropFirst().dropLast())))</p>"
            }
            let ns = trimmed as NSString
            guard let regex,
                  let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges == 3,
                  let rankRange = Range(match.range(at: 1), in: trimmed),
                  let textRange = Range(match.range(at: 2), in: trimmed) else {
                continue
            }
            let rank = String(trimmed[rankRange])
            let text = String(trimmed[textRange])
            items.append("""
            <li class="priority-item">
              <span class="priority-rank">\(escapeHTML(rank))</span>
              <span>\(escapeHTML(text))</span>
            </li>
            """)
        }
        if items.isEmpty {
            return "<p class=\"empty-note\">No open review items to prioritize.</p>"
        }
        return "<ul class=\"priority-list\">\(items.joined())</ul>"
    }

    private func renderGenericSection(_ lines: [String]) -> String {
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmedLines.isEmpty {
            return "<p class=\"empty-note\">No content.</p>"
        }
        let items = trimmedLines.map { "<li class=\"plain-item\">\(escapeHTML($0))</li>" }.joined()
        return "<ul class=\"plain-list\">\(items)</ul>"
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
    static func archivePatch(at path: String, book: BookConfig) throws -> String {
        try book.withSecurityScopedProjectRoot {
            let patchDirectory = book.patchDirectoryPath
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw PatchReviewError.archiveSourceMissing(path: source.lastPathComponent)
            }
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
}

enum PatchActivityLogger {
    static func filePath(book: BookConfig) -> String {
        URL(fileURLWithPath: book.patchDirectoryPath, isDirectory: true)
            .appendingPathComponent("activity.json")
            .path
    }

    static func load(book: BookConfig) -> [PatchActivityEntry] {
        (try? book.withSecurityScopedProjectRoot {
            let path = filePath(book: book)
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
            return (try? JSONDecoder.flexibleDates.decode([PatchActivityEntry].self, from: data)) ?? []
        }) ?? []
    }

    static func append(_ entry: PatchActivityEntry, book: BookConfig) {
        try? book.withSecurityScopedProjectRoot {
            var entries = loadUnscoped(book: book)
            entries.insert(entry, at: 0)
            entries = Array(entries.prefix(50))
            try FileHelpers.ensureDirectory(book.patchDirectoryPath)
            let data = try JSONEncoder.pretty.encode(entries)
            try data.write(to: URL(fileURLWithPath: filePath(book: book)), options: .atomic)
        }
    }

    private static func loadUnscoped(book: BookConfig) -> [PatchActivityEntry] {
        let path = filePath(book: book)
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder.flexibleDates.decode([PatchActivityEntry].self, from: data)) ?? []
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

    func gitLog(book: BookConfig, limit: Int = 1) async throws -> ShellCommandResult {
        let safeLimit = max(1, min(limit, 20))
        return try await ShellCommandRunner().runAsync(command: "git log -\(safeLimit) --oneline", book: book)
    }

    func gitCommit(message: String, changedPaths: [String], book: BookConfig) async throws -> ShellCommandResult {
        guard book.allowsPatchGitCommands else {
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
