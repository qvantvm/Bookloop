import Foundation

final class ProjectScanner {
    private let reviewParser = ReviewItemParser()

    func scan(book: BookConfig, config: BookProjectConfig) throws -> ProjectMap {
        let rootURL = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
        var entries: [ProjectFileEntry] = []
        let fm = FileManager.default

        let navigation = try NavConfigLoader.loadNavigation(for: book)
        for chapter in navigation.chapters {
            let relative = relativePath(for: URL(fileURLWithPath: chapter.markdownPath), rootURL: rootURL)
            let text = (try? String(contentsOfFile: chapter.markdownPath, encoding: .utf8)) ?? ""
            entries.append(ProjectFileEntry(
                relativePath: relative,
                kind: .chapter,
                title: chapter.title,
                headings: extractHeadings(from: text),
                wordCount: wordCount(text),
                lastModified: FileHelpers.modificationDate(path: chapter.markdownPath)
            ))
        }

        let contentRootURL = rootURL.appendingPathComponent(config.contentRoot)
        if fm.fileExists(atPath: contentRootURL.path) {
            scanDirectory(contentRootURL, rootURL: rootURL, kind: .chapter, into: &entries)
        }

        let navURL = rootURL.appendingPathComponent("bookloop.yml")
        if fm.fileExists(atPath: navURL.path) {
            addFile(url: navURL, rootURL: rootURL, kind: .config, into: &entries)
        }

        let scriptsURL = rootURL.appendingPathComponent("scripts")
        if fm.fileExists(atPath: scriptsURL.path) {
            scanDirectory(scriptsURL, rootURL: rootURL, kind: .script, into: &entries)
        }

        let reviewRootURL = rootURL.appendingPathComponent(config.reviewRoot)
        if fm.fileExists(atPath: reviewRootURL.path) {
            scanDirectory(reviewRootURL, rootURL: rootURL, kind: .review, into: &entries)
        }

        entries = dedupeEntries(entries)
        let reviews = try reviewParser.parseReviewItems(book: book)
        let openCount = reviews.filter { $0.status == .open }.count

        return ProjectMap(
            scannedAt: Date(),
            files: entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            chapterCount: entries.filter { $0.kind == .chapter }.count,
            reviewCount: entries.filter { $0.kind == .review }.count,
            openReviewCount: openCount
        )
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        return path
    }

    private func scanDirectory(_ directory: URL, rootURL: URL, kind: ProjectFileKind, into entries: inout [ProjectFileEntry]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ["md", "css", "yml", "yaml", "py"].contains(ext) else { continue }
            let fileKind: ProjectFileKind
            switch ext {
            case "css": fileKind = .stylesheet
            case "py": fileKind = .script
            default: fileKind = kind
            }
            addFile(url: url, rootURL: rootURL, kind: fileKind, into: &entries)
        }
    }

    private func addFile(url: URL, rootURL: URL, kind: ProjectFileKind, into entries: inout [ProjectFileEntry]) {
        let relative = relativePath(for: url, rootURL: rootURL)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let title = extractHeadings(from: text).first ?? url.deletingPathExtension().lastPathComponent
        entries.append(ProjectFileEntry(
            relativePath: relative,
            kind: kind,
            title: title,
            headings: extractHeadings(from: text),
            wordCount: wordCount(text),
            lastModified: FileHelpers.modificationDate(path: url.path)
        ))
    }

    private func dedupeEntries(_ entries: [ProjectFileEntry]) -> [ProjectFileEntry] {
        var byPath: [String: ProjectFileEntry] = [:]
        for entry in entries {
            if let existing = byPath[entry.relativePath] {
                if entry.headings.count > existing.headings.count || entry.wordCount > existing.wordCount {
                    byPath[entry.relativePath] = entry
                }
            } else {
                byPath[entry.relativePath] = entry
            }
        }
        return Array(byPath.values)
    }

    private func extractHeadings(from text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("#") else { return nil }
            return line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces).nilIfBlank
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
