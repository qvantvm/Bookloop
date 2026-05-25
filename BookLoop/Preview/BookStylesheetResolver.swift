import Foundation
import Yams

struct BookStylesheet: Equatable {
    var href: String
    var media: String?
}

enum BookStylesheetResolver {
    static func resolve(for book: BookConfig) -> [BookStylesheet] {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        let projectRoot = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
        var ordered: [BookStylesheet] = []
        var seen = Set<String>()

        func append(_ href: String) {
            let normalized = normalizedStylesheetHref(href, docsURL: docsURL, projectRoot: projectRoot)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            let fileURL = docsURL.appendingPathComponent(normalized)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            ordered.append(BookStylesheet(href: normalized, media: mediaQuery(for: normalized)))
        }

        for href in extraCSS(from: projectRoot.appendingPathComponent("mkdocs.yml")) {
            append(href)
        }

        let scanDirectories = [
            "stylesheets",
            "css",
            "assets/stylesheets",
            "assets/css"
        ]
        for directory in scanDirectories {
            let dirURL = docsURL.appendingPathComponent(directory, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            where file.pathExtension.lowercased() == "css" {
                append("\(directory)/\(file.lastPathComponent)")
            }
        }

        return ordered
    }

    private static func extraCSS(from mkdocsURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: mkdocsURL.path),
              let content = try? String(contentsOf: mkdocsURL, encoding: .utf8),
              let root = try? Yams.compose(yaml: content) else {
            return []
        }

        let extraNode: Node?
        switch root {
        case .mapping(let pairs):
            extraNode = pairs.first(where: { nodeString($0.key) == "extra_css" })?.value
        default:
            extraNode = nil
        }

        guard let extraNode else { return [] }
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
