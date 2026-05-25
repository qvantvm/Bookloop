import Foundation
import Yams

enum BookloopThemeParser {
    static func parse(from book: BookConfig) -> BookPreviewTheme? {
        guard let root = BookloopYamlConfig.loadRootNode(for: book),
              case .mapping(let pairs) = root,
              let themeNode = pairs.first(where: { nodeString($0.key) == "theme" })?.value,
              case .mapping(let themePairs) = themeNode else {
            return nil
        }

        var theme = BookPreviewTheme()

        if let paletteNode = themePairs.first(where: { nodeString($0.key) == "palette" })?.value,
           case .sequence(let paletteItems) = paletteNode {
            for item in paletteItems {
                guard case .mapping(let palettePairs) = item else { continue }
                let scheme = palettePairs.first(where: { nodeString($0.key) == "scheme" }).flatMap { nodeString($0.value) }
                let primary = palettePairs.first(where: { nodeString($0.key) == "primary" }).flatMap { nodeString($0.value) }
                let accent = palettePairs.first(where: { nodeString($0.key) == "accent" }).flatMap { nodeString($0.value) }

                if let primary { theme.primary = primary }
                if let accent { theme.accent = accent }
                if scheme == "default" || scheme == "light" {
                    theme.lightScheme = scheme ?? "default"
                } else if scheme == "slate" || scheme == "dark" {
                    theme.darkScheme = scheme ?? "slate"
                }
            }
        }

        return theme
    }

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}

enum BookStylesheetResolver {
    static func resolve(for book: BookConfig) -> BookPreviewStyleBundle {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        let projectRoot = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
        var ordered: [BookStylesheet] = []
        var seen = Set<String>()

        func append(_ href: String, media: String? = nil) {
            let normalized = normalizedStylesheetHref(href, docsURL: docsURL, projectRoot: projectRoot)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            let fileURL = docsURL.appendingPathComponent(normalized)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            ordered.append(BookStylesheet(href: normalized, media: media ?? mediaQuery(for: normalized)))
        }

        let hasProjectConfig = BookloopYamlConfig.resolveConfigPath(for: book) != nil
        let theme = hasProjectConfig
            ? (BookloopThemeParser.parse(from: book) ?? BookPreviewTheme())
            : nil
        let generatedThemeCSS: String
        let usesGeneratedTheme: Bool
        if let theme {
            generatedThemeCSS = BookloopThemeCSSGenerator.generate(theme: theme)
            usesGeneratedTheme = true
        } else {
            generatedThemeCSS = ""
            usesGeneratedTheme = false
        }

        for href in extraCSS(from: book) {
            append(href)
        }

        return BookPreviewStyleBundle(
            stylesheets: ordered,
            theme: theme,
            generatedThemeCSS: generatedThemeCSS,
            usesGeneratedTheme: usesGeneratedTheme
        )
    }

    private static func extraCSS(from book: BookConfig) -> [String] {
        guard let root = BookloopYamlConfig.loadRootNode(for: book),
              case .mapping(let pairs) = root,
              let extraNode = pairs.first(where: { nodeString($0.key) == "extra_css" })?.value else {
            return []
        }

        switch extraNode {
        case .sequence(let items):
            return items.compactMap { nodeString($0) }
        case .scalar(let scalar):
            return [scalar.string]
        default:
            return []
        }
    }

    private static func normalizedStylesheetHref(_ href: String, docsURL: URL, projectRoot: URL) -> String {
        var trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return ""
        }

        if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }

        if trimmed.hasPrefix("docs/") {
            trimmed = String(trimmed.dropFirst("docs/".count))
        }

        let asDocsURL = docsURL.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: asDocsURL.path) {
            return trimmed
        }

        let asRootURL = projectRoot.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: asRootURL.path) {
            let docsPath = docsURL.standardizedFileURL.path + "/"
            let rootPath = asRootURL.standardizedFileURL.path
            if rootPath.hasPrefix(docsPath) {
                return String(rootPath.dropFirst(docsPath.count))
            }
        }

        return trimmed
    }

    private static func mediaQuery(for href: String) -> String? {
        let name = URL(fileURLWithPath: href).lastPathComponent.lowercased()
        if name.contains("dark") && !name.contains("highlight") {
            return "(prefers-color-scheme: dark)"
        }
        if name.contains("light") {
            return "(prefers-color-scheme: light)"
        }
        return nil
    }

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}
