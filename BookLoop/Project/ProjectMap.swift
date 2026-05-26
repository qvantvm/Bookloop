import Foundation

enum ProjectFileKind: String, Codable, Equatable {
    case chapter
    case review
    case config
    case llmsContext
    case stylesheet
    case script
    case other
}

struct ProjectFileEntry: Identifiable, Codable, Equatable {
    var id: String { relativePath }
    var relativePath: String
    var kind: ProjectFileKind
    var title: String
    var headings: [String]
    var wordCount: Int
    var lastModified: Date?
}

struct ProjectMap: Codable, Equatable {
    var scannedAt: Date
    var files: [ProjectFileEntry]
    var chapterCount: Int
    var reviewCount: Int
    var openReviewCount: Int

    var compactSummary: String {
        "\(chapterCount) chapters, \(reviewCount) review files (\(openReviewCount) open)"
    }

    func files(matchingGlob glob: String?) -> [ProjectFileEntry] {
        guard let glob, !glob.isEmpty else { return files }
        return files.filter { GlobMatcher.matches(glob: glob, path: $0.relativePath) }
    }

    func relativePaths(matchingGlob glob: String?) -> [String] {
        files(matchingGlob: glob).map(\.relativePath)
    }
}

struct SearchResult: Codable, Equatable {
    var relativePath: String
    var lineNumber: Int
    var snippet: String
}

struct GrepResponse: Codable, Equatable {
    var pattern: String
    var matches: [SearchResult]
    var filesSearched: Int
    var truncated: Bool
}

enum GlobMatcher {
    static func matches(glob: String, path: String) -> Bool {
        let normalizedGlob = glob.replacingOccurrences(of: "\\", with: "/")
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")

        if normalizedGlob.contains("**") {
            let globParts = normalizedGlob.split(separator: "/").map(String.init)
            let pathParts = normalizedPath.split(separator: "/").map(String.init)
            return matchesComponents(globParts: globParts, pathParts: pathParts)
        }

        return fnmatch(normalizedGlob, normalizedPath, FNM_PATHNAME) == 0
            || fnmatch(normalizedGlob, normalizedPath, FNM_PATHNAME | FNM_CASEFOLD) == 0
    }

    private static func matchesComponents(globParts: [String], pathParts: [String]) -> Bool {
        if globParts.isEmpty { return pathParts.isEmpty }

        let head = globParts[0]
        let tail = Array(globParts.dropFirst())

        if head == "**" {
            if tail.isEmpty { return true }
            for index in 0...pathParts.count {
                if matchesComponents(globParts: tail, pathParts: Array(pathParts.dropFirst(index))) {
                    return true
                }
            }
            return false
        }

        guard let first = pathParts.first else { return false }
        guard matchesSegment(head, first) else { return false }
        return matchesComponents(globParts: tail, pathParts: Array(pathParts.dropFirst()))
    }

    private static func matchesSegment(_ pattern: String, _ segment: String) -> Bool {
        fnmatch(pattern, segment, 0) == 0 || fnmatch(pattern, segment, FNM_CASEFOLD) == 0
    }
}
