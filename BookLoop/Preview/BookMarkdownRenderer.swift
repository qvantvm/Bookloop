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

    static var materialTypesetCSS: String {
        loadText(resource: "material-typeset", ext: "css") ?? ""
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
        styleBundle: BookPreviewStyleBundle = BookPreviewStyleBundle(
            stylesheets: [],
            theme: nil,
            generatedThemeCSS: "",
            usesGeneratedTheme: false
        ),
        colorSchemeMode: PreviewColorSchemeMode = .system
    ) -> String {
        let safeTitle = escapeHTML(title)
        let chapterMeta = chapterID.map { "<meta name=\"chapter-id\" content=\"\(escapeHTML($0))\">" } ?? ""
        let bookStyles = stylesheetTags(styleBundle.stylesheets)
        let htmlAttrs = htmlAttributes(for: styleBundle.theme)
        let bodyClass = bodyClass(for: styleBundle)
        let themeScript = colorSchemeScript(for: styleBundle.theme, mode: colorSchemeMode)
        let generatedCSS = styleBundle.generatedThemeCSS
        return """
        <!doctype html>
        <html \(htmlAttrs)>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          \(chapterMeta)
          <style>\(PreviewResourceLoader.katexCSS)</style>
          <style>\(PreviewResourceLoader.materialTypesetCSS)</style>
          \(generatedCSS.isEmpty ? "" : "<style>\(generatedCSS)</style>")
          \(bookStyles)
          <style>\(PreviewResourceLoader.previewCSS)</style>
          <title>\(safeTitle)</title>
        </head>
        <body class="\(bodyClass)">
          <main class="md-content">
            <div class="md-content__inner">
              <article id="bookloop-content" class="md-typeset"></article>
            </div>
          </main>
          \(themeScript)
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

    private static func bodyClass(for styleBundle: BookPreviewStyleBundle) -> String {
        var classes = ["bookloop-preview"]
        if styleBundle.usesGeneratedTheme {
            classes.append("has-book-theme")
        }
        if !styleBundle.stylesheets.isEmpty {
            classes.append("has-book-stylesheet")
        }
        return classes.joined(separator: " ")
    }

    private static func htmlAttributes(for theme: BookPreviewTheme?) -> String {
        guard let theme else {
            return "lang=\"en\""
        }
        var attrs = [
            "lang=\"en\"",
            "data-md-color-switching=\"\"",
            "data-md-color-scheme=\"\(escapeHTML(theme.lightScheme))\"",
            "data-md-color-primary=\"\(escapeHTML(theme.primary))\"",
            "data-md-color-accent=\"\(escapeHTML(theme.accent))\""
        ]
        return attrs.joined(separator: " ")
    }

    private static func colorSchemeScript(for theme: BookPreviewTheme?, mode: PreviewColorSchemeMode) -> String {
        guard let theme else { return "" }
        let light = jsonString(theme.lightScheme)
        let dark = jsonString(theme.darkScheme)
        let initialMode = jsonString(mode.rawValue)
        return """
          <script>
            (function() {
              window.BookLoopPreview = window.BookLoopPreview || {};
              const lightScheme = \(light);
              const darkScheme = \(dark);
              let mode = \(initialMode);

              function resolvedScheme() {
                if (mode === 'light') return lightScheme;
                if (mode === 'dark') return darkScheme;
                return window.matchMedia('(prefers-color-scheme: dark)').matches ? darkScheme : lightScheme;
              }

              function applyBookLoopColorScheme() {
                document.documentElement.setAttribute('data-md-color-scheme', resolvedScheme());
              }

              window.BookLoopPreview.setColorSchemeMode = function(nextMode) {
                mode = nextMode;
                applyBookLoopColorScheme();
              };

              applyBookLoopColorScheme();
              window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function() {
                if (mode === 'system') applyBookLoopColorScheme();
              });
            })();
          </script>
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
    var colorSchemeMode: PreviewColorSchemeMode = .system

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

            let styleBundle = BookStylesheetResolver.resolve(for: book)

            let html = PreviewHTMLTemplate.document(
                markdownBody: parsed.body,
                title: title,
                chapterID: chapterID,
                currentChapterPath: normalizedPath,
                styleBundle: styleBundle,
                colorSchemeMode: colorSchemeMode
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
