import Foundation
import Yams

struct BookNavigationScanResult: Equatable {
    var chapters: [Chapter]
    var navItems: [ChapterNavItem]
    var usedLegacyMkDocsNav: Bool
    var navSourceDescription: String
}

enum NavConfigLoaderError: LocalizedError {
    case navSectionMissing
    case invalidNavFormat

    var errorDescription: String? {
        switch self {
        case .navSectionMissing:
            return "Navigation config is missing a top-level nav: section."
        case .invalidNavFormat:
            return "Navigation config could not be parsed."
        }
    }
}

enum NavConfigLoader {
    static func loadNavigation(for book: BookConfig) throws -> BookNavigationScanResult {
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)

        let navPath: String
        let sourceDescription: String
        let usedLegacy: Bool

        if let resolved = BookloopYamlConfig.resolveConfigPath(for: book) {
            navPath = resolved
            sourceDescription = URL(fileURLWithPath: resolved).lastPathComponent
            usedLegacy = BookloopYamlConfig.legacyStatus(for: resolved) != .none
        } else {
            return try fallbackFilesystemScan(book: book, docsURL: docsURL, sourceDescription: "docs/**/*.md")
        }

        let yamlContent = try String(contentsOfFile: navPath, encoding: .utf8)

        let navNodes = try parseNavYAML(yamlContent)
        guard !navNodes.isEmpty else {
            return try fallbackFilesystemScan(book: book, docsURL: docsURL, sourceDescription: sourceDescription)
        }

        var chaptersByPath: [String: Chapter] = [:]
        var orderedRelativePaths: [String] = []
        var order = 0
        let navItems = navNodes.flatMap { node -> [ChapterNavItem] in
            buildNavItems(
                from: node,
                docsURL: docsURL,
                chaptersByPath: &chaptersByPath,
                orderedRelativePaths: &orderedRelativePaths,
                order: &order
            )
        }

        mergeFilesystemChapters(docsURL: docsURL, chaptersByPath: &chaptersByPath)

        let navPathSet = Set(orderedRelativePaths)
        var chapters: [Chapter] = orderedRelativePaths.compactMap { relative in
            chaptersByPath.values.first { $0.relativePath == relative }
        }
        let orphanChapters = chaptersByPath.values
            .filter { !navPathSet.contains($0.relativePath) }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        chapters.append(contentsOf: orphanChapters)

        return BookNavigationScanResult(
            chapters: chapters,
            navItems: navItems,
            usedLegacyMkDocsNav: usedLegacy,
            navSourceDescription: sourceDescription
        )
    }

    static func createBookloopYAML(fromLegacyMkDocsAt path: String) throws -> String {
        try BookloopYamlConfig.createBookloopYAML(fromLegacyMkDocsAt: path)
    }

    @available(*, deprecated, renamed: "createBookloopYAML(fromLegacyMkDocsAt:)")
    static func createNavYAML(fromLegacyMkDocsAt path: String) throws -> String {
        try createBookloopYAML(fromLegacyMkDocsAt: path)
    }

    private static func parseNavYAML(_ content: String) throws -> [NavTreeNode] {
        guard let root = try Yams.compose(yaml: content) else { return [] }

        let navNode: Node
        switch root {
        case .mapping(let pairs):
            guard let navPair = pairs.first(where: { nodeString($0.key) == "nav" }) else {
                throw NavConfigLoaderError.navSectionMissing
            }
            navNode = navPair.value
        default:
            navNode = root
        }

        switch navNode {
        case .sequence(let items):
            return items.compactMap(parseNavNode)
        case .mapping(let pairs):
            return pairs.compactMap { pair in
                parseNavMappingPair(key: pair.key, value: pair.value)
            }
        default:
            throw NavConfigLoaderError.navSectionMissing
        }
    }

    private static func parseNavNode(_ node: Node) -> NavTreeNode? {
        switch node {
        case .scalar(let scalar):
            let path = ChapterResolver.normalizedDocsRelativeMarkdownPath(scalar.string)
            guard path.hasSuffix(".md") else { return nil }
            let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return NavTreeNode(title: title, path: path, children: [])

        case .mapping(let pairs):
            guard !pairs.isEmpty else { return nil }
            if pairs.count == 1, let pair = pairs.first {
                return parseNavMappingPair(key: pair.key, value: pair.value)
            }
            let children = pairs.compactMap { pair in
                parseNavMappingPair(key: pair.key, value: pair.value)
            }
            return NavTreeNode(title: "Section", path: nil, children: children)

        default:
            return nil
        }
    }

    private static func parseNavMappingPair(key: Node, value: Node) -> NavTreeNode? {
        guard let title = nodeString(key) else { return nil }

        switch value {
        case .scalar(let scalar):
            let normalized = ChapterResolver.normalizedDocsRelativeMarkdownPath(scalar.string)
            guard normalized.hasSuffix(".md") else { return nil }
            return NavTreeNode(title: title, path: normalized, children: [])

        case .sequence(let items):
            let children = items.compactMap(parseNavNode)
            return NavTreeNode(title: title, path: nil, children: children)

        case .mapping(let pairs):
            let children = pairs.compactMap { pair in
                parseNavMappingPair(key: pair.key, value: pair.value)
            }
            return NavTreeNode(title: title, path: nil, children: children)

        default:
            return nil
        }
    }

    private static func buildNavItems(
        from node: NavTreeNode,
        docsURL: URL,
        chaptersByPath: inout [String: Chapter],
        orderedRelativePaths: inout [String],
        order: inout Int
    ) -> [ChapterNavItem] {
        if let path = node.path {
            let chapter = chapterFromMarkdown(
                url: docsURL.appendingPathComponent(path),
                docsURL: docsURL,
                titleOverride: node.title,
                order: order
            )
            order += 1
            chaptersByPath[chapter.markdownPath] = chapter
            if !orderedRelativePaths.contains(chapter.relativePath) {
                orderedRelativePaths.append(chapter.relativePath)
            }
            return [ChapterNavItem(title: node.title, href: chapter.relativePath)]
        }

        let children = node.children.flatMap { child in
            buildNavItems(
                from: child,
                docsURL: docsURL,
                chaptersByPath: &chaptersByPath,
                orderedRelativePaths: &orderedRelativePaths,
                order: &order
            )
        }
        if children.isEmpty {
            return [ChapterNavItem(title: node.title, href: "", children: [])]
        }
        return [ChapterNavItem(title: node.title, href: "", children: children)]
    }

    private static func fallbackFilesystemScan(book: BookConfig, docsURL: URL, sourceDescription: String) throws -> BookNavigationScanResult {
        var chaptersByPath: [String: Chapter] = [:]
        mergeFilesystemChapters(docsURL: docsURL, chaptersByPath: &chaptersByPath)
        let chapters = chaptersByPath.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        let navItems = chapters.map { ChapterNavItem(title: $0.title, href: $0.relativePath) }
        return BookNavigationScanResult(
            chapters: chapters,
            navItems: navItems,
            usedLegacyMkDocsNav: false,
            navSourceDescription: sourceDescription
        )
    }

    private static func mergeFilesystemChapters(docsURL: URL, chaptersByPath: inout [String: Chapter]) {
        guard FileManager.default.fileExists(atPath: docsURL.path),
              let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            if chaptersByPath[url.path] == nil {
                chaptersByPath[url.path] = chapterFromMarkdown(url: url, docsURL: docsURL, titleOverride: nil, order: nil)
            }
        }
    }

    private static func chapterFromMarkdown(url: URL, docsURL: URL, titleOverride: String?, order: Int?) -> Chapter {
        let docsPath = docsURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relativePath = filePath.hasPrefix(docsPath + "/")
            ? String(filePath.dropFirst(docsPath.count + 1))
            : url.lastPathComponent
        relativePath = ChapterResolver.normalizedDocsRelativeMarkdownPath(relativePath)
        let frontmatter = parseFrontmatter(path: url.path)
        let id = frontmatter["id"] ?? relativePath.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")
        let title = titleOverride ?? frontmatter["title"] ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized
        return Chapter(id: id, title: title, markdownPath: url.path, relativePath: relativePath, urlSlug: relativePath, order: order)
    }

    private static func parseFrontmatter(path: String) -> [String: String] {
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

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}

private struct NavTreeNode {
    var title: String
    var path: String?
    var children: [NavTreeNode]
}

typealias BookNavScanner = NavConfigLoader
