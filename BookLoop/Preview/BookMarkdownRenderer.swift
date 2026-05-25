import Foundation

enum PreviewResourceLoader {
    static func url(forResource name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Preview/Resources")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func loadText(resource name: String, ext: String) -> String? {
        guard let url = url(forResource: name, ext: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static var previewCSS: String {
        loadText(resource: "preview", ext: "css") ?? ""
    }

    static var previewJS: String {
        loadText(resource: "preview", ext: "js") ?? ""
    }

    static var markdownItJS: String {
        loadText(resource: "markdown-it.min", ext: "js") ?? ""
    }

    static var katexJS: String {
        loadText(resource: "katex.min", ext: "js") ?? ""
    }

    static var katexAutoRenderJS: String {
        loadText(resource: "katex-auto-render.min", ext: "js") ?? ""
    }

    static var katexCSS: String {
        loadText(resource: "katex.min", ext: "css") ?? ""
    }
}

enum PreviewHTMLTemplate {
    static func document(
        markdownBody: String,
        title: String,
        chapterID: String?,
        currentChapterPath: String,
        stylesheets: [BookStylesheet] = []
    ) -> String {
        let safeTitle = escapeHTML(title)
        let chapterMeta = chapterID.map { "<meta name=\"chapter-id\" content=\"\(escapeHTML($0))\">" } ?? ""
        let bookStyles = stylesheetTags(stylesheets)
        let bodyClass = stylesheets.isEmpty ? "bookloop-preview" : "bookloop-preview has-book-stylesheet"
        return """
        <!doctype html>
        <html lang="en" style="color-scheme: light dark;">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          \(chapterMeta)
          <style>\(PreviewResourceLoader.katexCSS)</style>
          <style>\(PreviewResourceLoader.previewCSS)</style>
          \(bookStyles)
          <title>\(safeTitle)</title>
        </head>
        <body class="\(bodyClass)">
          <article id="bookloop-content" class="md-content md-typeset"></article>
          <script>\(PreviewResourceLoader.markdownItJS)</script>
          <script>\(PreviewResourceLoader.katexJS)</script>
          <script>\(PreviewResourceLoader.katexAutoRenderJS)</script>
          <script>\(PreviewResourceLoader.previewJS)</script>
          <script>
            (function() {
              const currentPath = \(jsonString(currentChapterPath));
              const markdown = \(jsonString(markdownBody));
              const html = window.BookLoopPreview.render(markdown, currentPath);
              document.getElementById('bookloop-content').innerHTML = html;
              window.BookLoopPreview.renderMath(document.getElementById('bookloop-content'));
            })();
          </script>
        </body>
        </html>
        """
    }

    private static func stylesheetTags(_ stylesheets: [BookStylesheet]) -> String {
        stylesheets.map { sheet in
            let media = sheet.media.map { " media=\"\($0)\"" } ?? ""
            let href = escapeHTML(sheet.href)
            return "<link rel=\"stylesheet\" href=\"\(href)\"\(media)>"
        }
        .joined(separator: "\n          ")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

struct RenderedBookChapter: Equatable {
    var html: String
    var title: String
    var chapterID: String?
    var relativePath: String
    var baseDirectory: URL
}

enum BookMarkdownRendererError: LocalizedError {
    case chapterNotFound(String)
    case unreadableChapter(String)

    var errorDescription: String? {
        switch self {
        case .chapterNotFound(let path):
            return "Chapter not found: \(path)"
        case .unreadableChapter(let path):
            return "Could not read chapter: \(path)"
        }
    }
}

final class BookMarkdownRenderer {
    func renderChapter(book: BookConfig, relativePath: String) throws -> RenderedBookChapter {
        let normalizedPath = ChapterResolver.normalizedDocsRelativeMarkdownPath(relativePath)
        let docsURL = URL(fileURLWithPath: book.docsPath ?? book.suggestedPath("docs"), isDirectory: true)
        let fileURL = docsURL.appendingPathComponent(normalizedPath)

        return try book.withSecurityScopedProjectRoot {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw BookMarkdownRendererError.chapterNotFound(normalizedPath)
            }
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                throw BookMarkdownRendererError.unreadableChapter(normalizedPath)
            }

            let parsed = MarkdownFrontmatter.parse(raw)
            let title = parsed.frontmatter["title"] ?? fileURL.deletingPathExtension().lastPathComponent
            let chapterID = parsed.frontmatter["id"]
                ?? normalizedPath.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")

            let stylesheets = BookStylesheetResolver.resolve(for: book)

            let html = PreviewHTMLTemplate.document(
                markdownBody: parsed.body,
                title: title,
                chapterID: chapterID,
                currentChapterPath: normalizedPath,
                stylesheets: stylesheets
            )

            return RenderedBookChapter(
                html: html,
                title: title,
                chapterID: chapterID,
                relativePath: normalizedPath,
                baseDirectory: docsURL
            )
        }
    }
}

enum MarkdownFrontmatter {
    struct Parsed {
        var frontmatter: [String: String]
        var body: String
    }

    static func parse(_ content: String) -> Parsed {
        guard content.hasPrefix("---") else {
            return Parsed(frontmatter: [:], body: content)
        }
        let lines = content.components(separatedBy: .newlines)
        var frontmatter: [String: String] = [:]
        var bodyStart = 1
        for (offset, line) in lines.dropFirst().enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = offset + 2
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                frontmatter[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        let body = lines.dropFirst(bodyStart).joined(separator: "\n")
        return Parsed(frontmatter: frontmatter, body: body)
    }
}
