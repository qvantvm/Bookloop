import Foundation
import Yams

enum BookLLMsTxtGenerator {
    struct GeneratedFile: Equatable {
        var relativePath: String
        var absolutePath: String
        var content: String
    }

    enum GeneratorError: LocalizedError {
        case noChapters

        var errorDescription: String? {
            switch self {
            case .noChapters:
                return "No chapters found under docs/. Add chapters to bookloop.yml nav or docs/**/*.md."
            }
        }
    }

    static func preferredOutputRelativePath(for book: BookConfig) -> String {
        configuredOutputPath(from: book) ?? "llms.txt"
    }

    static func generate(for book: BookConfig) throws -> String {
        let navigation = try NavConfigLoader.loadNavigation(for: book)
        guard !navigation.chapters.isEmpty else {
            throw GeneratorError.noChapters
        }

        let metadata = bookMetadata(from: book)
        var lines: [String] = [
            "# \(metadata.name)",
            ""
        ]

        if let description = metadata.description?.nilIfBlank {
            lines.append("> \(description)")
            lines.append("")
        }

        lines.append(contentsOf: purposeSection())
        lines.append("## Chapters")
        lines.append("")

        for chapter in navigation.chapters {
            lines.append(contentsOf: chapterLines(for: chapter))
        }

        lines.append(contentsOf: reviewWorkflowSection())
        if hasClaimsDirectory(book: book) {
            lines.append(contentsOf: claimsWorkflowSection())
        }
        lines.append(contentsOf: bookLoopInstructionsSection())

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func write(for book: BookConfig, relativePath: String? = nil) throws -> GeneratedFile {
        let relative = relativePath?.nilIfBlank ?? preferredOutputRelativePath(for: book)
        let content = try generate(for: book)
        let absolute = book.suggestedPath(relative)

        try book.withSecurityScopedProjectRoot {
            let url = URL(fileURLWithPath: absolute)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        return GeneratedFile(relativePath: relative, absolutePath: absolute, content: content)
    }

    private static func bookMetadata(from book: BookConfig) -> (name: String, description: String?) {
        var name = book.displayName
        var description: String?

        if let root = BookloopYamlConfig.loadRootNode(for: book),
           case .mapping(let pairs) = root {
            if let siteName = pairs.first(where: { nodeString($0.key) == "site_name" }).flatMap({ nodeString($0.value) }) {
                name = siteName
            }
            description = pairs.first(where: { nodeString($0.key) == "site_description" }).flatMap { nodeString($0.value) }
        }

        return (name, description)
    }

    private static func purposeSection() -> [String] {
        [
            "## Purpose",
            "",
            "This repository is a Markdown-first living book.",
            "Chapters live in docs/. Review feedback lives in reviews/.",
            "BookLoop provides native preview, reviews, and an editing agent.",
            ""
        ]
    }

    private static func chapterLines(for chapter: Chapter) -> [String] {
        let raw = (try? String(contentsOfFile: chapter.markdownPath, encoding: .utf8)) ?? ""
        let frontmatter = MarkdownFrontmatter.parse(raw).frontmatter

        let id = frontmatter["id"]?.nilIfBlank ?? chapter.id
        let title = frontmatter["title"]?.nilIfBlank ?? chapter.title
        let status = frontmatter["status"]?.nilIfBlank ?? "unknown"
        let stability = frontmatter["stability"]?.nilIfBlank ?? "unknown"

        var lines = [
            "- \(id): \(title) [\(status), \(stability)]"
        ]

        if let summary = frontmatter["summary"]?.nilIfBlank {
            lines.append("  - \(summary)")
        } else if let excerpt = firstBodyExcerpt(from: MarkdownFrontmatter.parse(raw).body) {
            lines.append("  - \(excerpt)")
        }

        lines.append("  - Source: docs/\(chapter.relativePath)")
        lines.append("")
        return lines
    }

    private static func firstBodyExcerpt(from body: String) -> String? {
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            return String(trimmed.prefix(200))
        }
        return nil
    }

    private static func reviewWorkflowSection() -> [String] {
        [
            "## Review Workflow",
            "",
            "1. Read reviews/cumulative_review.md and reviews/review_index.json when present.",
            "2. Inspect open items in reviews/review_items/.",
            "3. Edit chapter Markdown in docs/.",
            "4. Resolve items in BookLoop (Reviews tool) or archive them under reviews/resolved/.",
            "5. Regenerate llms.txt from BookLoop book settings after large structural changes.",
            ""
        ]
    }

    private static func claimsWorkflowSection() -> [String] {
        [
            "## Claim Workflow",
            "",
            "1. Track factual claims in claims/claims.jsonl and claims/claims_by_chapter/*.jsonl.",
            "2. Flag fast-moving or volatile claims for refresh.",
            "3. Do not invent citations; add TODOs when sources are missing.",
            ""
        ]
    }

    private static func bookLoopInstructionsSection() -> [String] {
        [
            "## Instructions for BookLoop",
            "",
            "Use bookloop/style_guide.md when present.",
            "Prefer concrete examples, comparison tables for confused concepts, and sharper definitions.",
            "Preserve chapter structure unless there is a clear reason to improve it.",
            "Do not silently delete technical content.",
            ""
        ]
    }

    private static func hasClaimsDirectory(book: BookConfig) -> Bool {
        let claimsPath = book.suggestedPath("claims")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: claimsPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func configuredOutputPath(from book: BookConfig) -> String? {
        guard let root = BookloopYamlConfig.loadRootNode(for: book),
              case .mapping(let pairs) = root,
              let node = pairs.first(where: { nodeString($0.key) == "llms_txt" })?.value else {
            return nil
        }

        switch node {
        case .scalar(let scalar):
            return normalizeRelativePath(scalar.string)
        case .sequence(let items):
            for item in items {
                if case .scalar(let scalar) = item,
                   let path = normalizeRelativePath(scalar.string) {
                    return path
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func normalizeRelativePath(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}
