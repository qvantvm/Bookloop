import Foundation

final class FeedbackAPIClient {
    func checkHealth(baseURL: String) async throws -> HealthResponse {
        try await LocalHTTPClient().get(baseURL: baseURL, path: "/api/health")
    }

    func submitReview(baseURL: String, request: ReviewRequest) async throws -> ReviewResponse {
        try await LocalHTTPClient().post(baseURL: baseURL, path: "/api/review", body: request)
    }
}

final class AgentHarnessClient {
    func checkHealth(baseURL: String) async throws -> HealthResponse {
        try await LocalHTTPClient().get(baseURL: baseURL, path: "/api/health")
    }

    func submitFixReviewsTask(baseURL: String, request: AgentTaskRequest) async throws -> AgentTaskResponse {
        try await LocalHTTPClient().post(baseURL: baseURL, path: "/api/tasks/fix_reviews", body: request)
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
                let markdown = pathPart.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                guard markdown.hasSuffix(".md") else { return nil }
                return chapterFromMarkdown(url: docsURL.appendingPathComponent(markdown), docsURL: docsURL, titleOverride: title, order: nil)
            }
    }

    private func chapterFromMarkdown(url: URL, docsURL: URL, titleOverride: String? = nil, order: Int?) -> Chapter {
        let relativePath = url.path.replacingOccurrences(of: docsURL.path + "/", with: "")
        let frontmatter = parseFrontmatter(path: url.path)
        let id = frontmatter["id"] ?? relativePath.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")
        let title = titleOverride ?? frontmatter["title"] ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized
        let slug = relativePath == "index.md" ? "" : relativePath.replacingOccurrences(of: ".md", with: "/").replacingOccurrences(of: "index/", with: "")
        return Chapter(id: id, title: title, markdownPath: url.path, relativePath: relativePath, urlSlug: slug.nilIfBlank, order: order)
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
            body: section(named: ["body", "observation", "review", "details"], content: content) ?? bodyWithoutFrontmatterAndTitle(content),
            suggestedFix: value(frontmatter, keys: ["suggested_fix", "suggestedFix"]) ?? section(named: ["suggested fix", "suggested_fix"], content: content),
            status: status,
            createdAt: createdAt
        )
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
        for (index, line) in lines.enumerated() where line.hasPrefix("##") {
            let heading = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard names.contains(heading) else { continue }
            let rest = lines.dropFirst(index + 1)
            let sectionLines = rest.prefix { !$0.hasPrefix("##") }
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

final class PatchParser {
    func scanPatchDirectory(path: String) -> [PatchProposal] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { ["patch", "diff"].contains($0.pathExtension.lowercased()) }
            .compactMap(parsePatch(url:))
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
}

final class PatchApplier {
    func check(patch: PatchProposal, book: BookConfig) throws -> ShellCommandResult {
        try ShellCommandRunner().run(command: "git apply --check \(shellQuoted(patch.filePath))", workingDirectory: book.projectRootPath)
    }

    func apply(patch: PatchProposal, book: BookConfig) throws -> ShellCommandResult {
        let checkResult = try check(patch: patch, book: book)
        guard checkResult.exitCode == 0 else { return checkResult }
        return try ShellCommandRunner().run(command: "git apply \(shellQuoted(patch.filePath))", workingDirectory: book.projectRootPath)
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
