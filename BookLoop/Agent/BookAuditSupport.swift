import Foundation

enum BookAuditKind: String, Codable {
    case consistency
    case logicalFlow

    var reportLabel: String {
        switch self {
        case .consistency: return "consistency"
        case .logicalFlow: return "logical-flow"
        }
    }

    var reviewType: String {
        switch self {
        case .consistency: return "consistency"
        case .logicalFlow: return "logical_flow"
        }
    }
}

struct BookAuditFinding: Codable, Equatable, Identifiable {
    var id: UUID
    var category: String
    var severity: String
    var title: String
    var detail: String
    var chapter: String?
    var evidencePaths: [String]
    var suggestedFix: String?

    init(
        id: UUID = UUID(),
        category: String,
        severity: String,
        title: String,
        detail: String,
        chapter: String? = nil,
        evidencePaths: [String] = [],
        suggestedFix: String? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.chapter = chapter
        self.evidencePaths = evidencePaths
        self.suggestedFix = suggestedFix
    }
}

struct BookTableOfContents: Codable, Equatable {
    var navSource: String
    var chapterCount: Int
    var outline: String
}

enum BookTableOfContentsBuilder {
    static func build(book: BookConfig, projectMap: ProjectMap) -> BookTableOfContents {
        let nav = (try? NavConfigLoader.loadNavigation(for: book))
        var lines: [String] = []
        var navSource = "project scan"

        if let nav {
            navSource = nav.navSourceDescription
            lines.append("Navigation (\(nav.chapters.count) chapters):")
            for (index, chapter) in nav.chapters.enumerated() {
                let marker = String(format: "%3d", index + 1)
                lines.append("\(marker). [\(chapter.id)] \(chapter.title) — docs/\(chapter.relativePath)")
            }
        }

        let chapterFiles = projectMap.files.filter { $0.kind == .chapter }
        if !chapterFiles.isEmpty {
            lines.append("")
            lines.append("Chapter headings (from scan):")
            for file in chapterFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
                let headingPreview = file.headings.prefix(12).joined(separator: " → ")
                let suffix = file.headings.count > 12 ? " …" : ""
                lines.append("- \(file.relativePath) (\(file.wordCount) words): \(headingPreview)\(suffix)")
            }
        }

        return BookTableOfContents(
            navSource: navSource,
            chapterCount: nav?.chapters.count ?? chapterFiles.count,
            outline: lines.joined(separator: "\n")
        )
    }
}

struct BookAuditReport: Equatable {
    var relativePath: String
    var absolutePath: String
    var reviewItemIDs: [String]
}

enum BookAuditReportWriter {
    static func auditReportsDirectory(for book: BookConfig) -> String {
        if let bookloopPath = book.bookloopPath {
            return URL(fileURLWithPath: bookloopPath, isDirectory: true)
                .appendingPathComponent("audit-reports", isDirectory: true)
                .path
        }
        return book.suggestedPath("bookloop/audit-reports")
    }

    static func write(
        kind: BookAuditKind,
        task: AgentTask,
        sessionID: UUID,
        summary: String,
        findings: [BookAuditFinding],
        project: BookProject
    ) throws -> BookAuditReport {
        try project.withSecurityScoped {
            let directory = auditReportsDirectory(for: project.book)
            try FileHelpers.ensureDirectory(directory)

            let timestamp = DateFormatting.taskFilename.string(from: Date())
            let filename = "\(timestamp)-\(kind.reportLabel)-audit.md"
            let fileURL = URL(fileURLWithPath: directory).appendingPathComponent(filename)

            let markdown = buildReportMarkdown(
                kind: kind,
                task: task,
                sessionID: sessionID,
                summary: summary,
                findings: findings,
                project: project
            )
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

            let rootPath = URL(fileURLWithPath: project.book.projectRootPath, isDirectory: true).standardizedFileURL.path
            let standardized = fileURL.standardizedFileURL.path
            let relative: String
            if standardized.hasPrefix(rootPath) {
                relative = String(standardized.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                relative = "bookloop/audit-reports/\(filename)"
            }

            let reviewIDs = try writeReviewItems(
                findings: findings,
                kind: kind,
                book: project.book
            )

            return BookAuditReport(
                relativePath: relative,
                absolutePath: fileURL.path,
                reviewItemIDs: reviewIDs
            )
        }
    }

    private static func buildReportMarkdown(
        kind: BookAuditKind,
        task: AgentTask,
        sessionID: UUID,
        summary: String,
        findings: [BookAuditFinding],
        project: BookProject
    ) -> String {
        let title = task.type.displayName
        var lines: [String] = [
            "# \(title)",
            "",
            "- Session: `\(sessionID.uuidString)`",
            "- Created: \(ISO8601DateFormatter().string(from: Date()))",
            "- Book: \(project.book.displayName)",
            "- Chapters scanned: \(project.projectMap.chapterCount)",
            ""
        ]

        if !task.instruction.isEmpty {
            lines.append("## User focus")
            lines.append("")
            lines.append(task.instruction)
            lines.append("")
        }

        lines.append("## Executive summary")
        lines.append("")
        lines.append(summary.isEmpty ? "_No summary provided._" : summary)
        lines.append("")

        lines.append("## Findings (\(findings.count))")
        lines.append("")

        if findings.isEmpty {
            lines.append("_No structured findings were recorded. Re-run the audit or check the agent activity log._")
        } else {
            for (index, finding) in findings.enumerated() {
                lines.append("### \(index + 1). \(finding.title)")
                lines.append("")
                lines.append("- Category: \(finding.category)")
                lines.append("- Severity: \(finding.severity)")
                if let chapter = finding.chapter?.nilIfBlank {
                    lines.append("- Chapter: `\(chapter)`")
                }
                if !finding.evidencePaths.isEmpty {
                    lines.append("- Evidence: \(finding.evidencePaths.map { "`\($0)`" }.joined(separator: ", "))")
                }
                lines.append("")
                lines.append(finding.detail)
                if let fix = finding.suggestedFix?.nilIfBlank {
                    lines.append("")
                    lines.append("**Suggested fix:** \(fix)")
                }
                lines.append("")
            }
        }

        lines.append("## Next steps")
        lines.append("")
        lines.append("1. Triage findings in Tools → Reviews.")
        lines.append("2. Run **Apply Review Feedback** or a custom agent task to stage fixes.")
        lines.append("3. Review and apply patches from Tools → Patches.")
        lines.append("")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeReviewItems(findings: [BookAuditFinding], kind: BookAuditKind, book: BookConfig) throws -> [String] {
        let writer = ReviewItemWriter()
        var ids: [String] = []

        for finding in findings {
            let severity = finding.severity.lowercased()
            guard severity == "major" || severity == "critical" || severity == "high" else { continue }

            let chapter = resolvedChapterID(finding.chapter, book: book)
            guard ChapterResolver.feedbackAPIChapterExists(chapter, book: book) else { continue }

            var body = finding.detail
            if !finding.evidencePaths.isEmpty {
                body += "\n\nEvidence:\n" + finding.evidencePaths.map { "- `\($0)`" }.joined(separator: "\n")
            }

            let request = ReviewRequest(
                chapter: chapter,
                type: kind.reviewType,
                severity: normalizedSeverity(finding.severity),
                title: finding.title,
                body: body,
                section: finding.category.nilIfBlank,
                suggested_fix: finding.suggestedFix
            )
            let response = try writer.write(request: request, book: book)
            ids.append(response.id)
        }

        return ids
    }

    private static func normalizedSeverity(_ raw: String) -> String {
        switch raw.lowercased() {
        case "critical", "high": return "high"
        case "major", "medium": return "medium"
        default: return "low"
        }
    }

    private static func resolvedChapterID(_ raw: String?, book: BookConfig) -> String {
        if let raw = raw?.nilIfBlank,
           ChapterResolver.feedbackAPIChapterExists(raw, book: book) {
            return ChapterResolver.normalizedAPIChapterID(raw, book: book)
        }
        return fallbackChapterID(book: book)
    }

    private static func fallbackChapterID(book: BookConfig) -> String {
        for candidate in ["index", "home", "introduction", "intro", "preface"] {
            if ChapterResolver.feedbackAPIChapterExists(candidate, book: book) {
                return candidate
            }
        }
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil) {
            let markdown = entries
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = markdown.first {
                return first.deletingPathExtension().lastPathComponent
            }
        }
        return "index"
    }
}
