import Foundation
import Combine

struct BookProject: Equatable {
    var book: BookConfig
    var config: BookProjectConfig
    var projectMap: ProjectMap
    var hasGit: Bool
    var currentChapterID: String?

    var rootURL: URL {
        URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
    }

    var pathGuard: ProjectPathGuard {
        ProjectPathGuard(rootURL: rootURL, config: config)
    }

    var sessionsDirectory: URL {
        rootURL.appendingPathComponent(".bookloop/sessions", isDirectory: true)
    }

    func withSecurityScoped<T>(_ work: () throws -> T) rethrows -> T {
        try book.withSecurityScopedProjectRoot(work)
    }
}

@MainActor
final class BookProjectStore: ObservableObject {
    @Published private(set) var project: BookProject?
    @Published private(set) var configMissing = false
    @Published private(set) var lastError: String?

    private let scanner = ProjectScanner()
    let searchIndex = SearchIndex()

    func refresh(book: BookConfig?, currentChapterID: String? = nil) {
        guard let book, !book.projectRootPath.isEmpty else {
            project = nil
            configMissing = false
            lastError = nil
            return
        }

        do {
            var missingConfig = false
            let config = try book.withSecurityScopedProjectRoot {
                if let loaded = try BookProjectConfig.load(from: book) {
                    return loaded
                }
                missingConfig = true
                return BookProjectConfig.defaults(for: book)
            }

            let map = try book.withSecurityScopedProjectRoot {
                try scanner.scan(book: book, config: config)
            }

            try book.withSecurityScopedProjectRoot {
                try searchIndex.rebuild(from: map, book: book, config: config)
            }

            let gitPath = URL(fileURLWithPath: book.projectRootPath).appendingPathComponent(".git").path
            let hasGit = FileManager.default.fileExists(atPath: gitPath)

            project = BookProject(
                book: book,
                config: config,
                projectMap: map,
                hasGit: hasGit,
                currentChapterID: currentChapterID
            )
            configMissing = missingConfig
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func initializeConfig(for book: BookConfig) throws {
        let config = BookProjectConfig.defaults(for: book)
        try book.withSecurityScopedProjectRoot {
            try BookProjectConfig.save(config, book: book)
        }
        refresh(book: book, currentChapterID: project?.currentChapterID)
    }

    func repairWriteGlobs(for book: BookConfig) throws {
        let existing = try book.withSecurityScopedProjectRoot {
            try BookProjectConfig.load(from: book) ?? BookProjectConfig.defaults(for: book)
        }
        let repaired = existing.withStandardWriteGlobs()
        try book.withSecurityScopedProjectRoot {
            try BookProjectConfig.save(repaired, book: book)
        }
        refresh(book: book, currentChapterID: project?.currentChapterID)
    }
}
