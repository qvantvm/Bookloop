import Foundation

struct BookProjectAgentConfig: Codable, Equatable {
    var model: String?
}

struct BookProjectConfig: Codable, Equatable {
    var projectName: String
    var contentRoot: String
    var reviewRoot: String
    var buildCommand: String
    var previewCommand: String
    var protectedPaths: [String]
    var allowedWriteGlobs: [String]
    var agent: BookProjectAgentConfig

    static let configRelativePath = ".bookloop/config.json"

    static let standardWriteGlobs: [String] = [
        "docs/*.md",
        "docs/**/*.md",
        "docs/*.css",
        "docs/**/*.css",
        "docs/*.yml",
        "docs/**/*.yml",
        "docs/*.yaml",
        "docs/**/*.yaml",
        "mkdocs.yml",
        "reviews/*.md",
        "reviews/**/*.md"
    ]

    static func defaults(for book: BookConfig) -> BookProjectConfig {
        BookProjectConfig(
            projectName: book.displayName,
            contentRoot: "docs",
            reviewRoot: "reviews/review_items",
            buildCommand: book.validationCommand?.nilIfBlank ?? "mkdocs build",
            previewCommand: book.mkdocsServeCommand?.nilIfBlank ?? "mkdocs serve",
            protectedPaths: [".git", ".env", "secrets", ".bookloop"],
            allowedWriteGlobs: standardWriteGlobs,
            agent: BookProjectAgentConfig(model: nil)
        )
    }

    func withStandardWriteGlobs() -> BookProjectConfig {
        var updated = self
        for glob in Self.standardWriteGlobs where !updated.allowedWriteGlobs.contains(glob) {
            updated.allowedWriteGlobs.append(glob)
        }
        return updated
    }

    static func load(from book: BookConfig) throws -> BookProjectConfig? {
        let url = configURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(BookProjectConfig.self, from: data)
        return config.withStandardWriteGlobs()
    }

    static func save(_ config: BookProjectConfig, book: BookConfig) throws {
        let url = configURL(for: book)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: [.atomic])
    }

    static func configURL(for book: BookConfig) -> URL {
        URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(configRelativePath)
    }

    func resolvedModel(appDefault: String) -> String {
        agent.model?.nilIfBlank ?? appDefault
    }
}

enum BookProjectConfigError: LocalizedError {
    case missingProjectRoot
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectRoot: return "Project root is not configured."
        case .invalidPath(let path): return "Invalid path: \(path)"
        }
    }
}
