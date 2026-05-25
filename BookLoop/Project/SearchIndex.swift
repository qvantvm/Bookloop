import Foundation

final class SearchIndex {
    private var documents: [IndexedDocument] = []

    struct IndexedDocument {
        let relativePath: String
        let title: String
        let headings: [String]
        let lines: [String]
    }

    func rebuild(from map: ProjectMap, book: BookConfig, config: BookProjectConfig) throws {
        let guard_ = pathGuard(book: book, config: config)
        var docs: [IndexedDocument] = []
        for entry in map.files where entry.kind == .chapter || entry.kind == .review || entry.kind == .config {
            if guard_.isProtected(relativePath: entry.relativePath) { continue }
            guard let url = try? guard_.validateRead(entry.relativePath),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            docs.append(IndexedDocument(
                relativePath: entry.relativePath,
                title: entry.title,
                headings: entry.headings,
                lines: text.components(separatedBy: .newlines)
            ))
        }
        documents = docs
    }

    func searchText(_ query: String, glob: String?, limit: Int, book: BookConfig, config: BookProjectConfig) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        let maxResults = max(1, min(limit, 50))
        var results: [SearchResult] = []

        for doc in documents {
            if let glob, !GlobMatcher.matches(glob: glob, path: doc.relativePath) { continue }

            if doc.title.lowercased().contains(needle) {
                results.append(SearchResult(relativePath: doc.relativePath, lineNumber: 0, snippet: "Title: \(doc.title)"))
            }

            for (index, heading) in doc.headings.enumerated() where heading.lowercased().contains(needle) {
                results.append(SearchResult(relativePath: doc.relativePath, lineNumber: index + 1, snippet: "Heading: \(heading)"))
            }

            for (lineIndex, line) in doc.lines.enumerated() where line.lowercased().contains(needle) {
                results.append(SearchResult(
                    relativePath: doc.relativePath,
                    lineNumber: lineIndex + 1,
                    snippet: line.trimmingCharacters(in: .whitespaces).prefix(200).description
                ))
            }

            if results.count >= maxResults { break }
        }

        return Array(results.prefix(maxResults))
    }

    private func pathGuard(book: BookConfig, config: BookProjectConfig) -> ProjectPathGuard {
        ProjectPathGuard(rootURL: URL(fileURLWithPath: book.projectRootPath, isDirectory: true), config: config)
    }
}
