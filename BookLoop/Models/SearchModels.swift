import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Codable {
    case wholeProject
    case chaptersOnly
    case reviewsOnly
    case chaptersAndReviews

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeProject: return "Whole project"
        case .chaptersOnly: return "Chapters only"
        case .reviewsOnly: return "Reviews only"
        case .chaptersAndReviews: return "Chapters + reviews"
        }
    }

    var defaultGlob: String {
        switch self {
        case .wholeProject: return "**/*"
        case .chaptersOnly: return "docs/**/*.md"
        case .reviewsOnly: return "reviews/**"
        case .chaptersAndReviews: return "**/*"
        }
    }

    func matchesPath(_ relativePath: String) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        switch self {
        case .wholeProject:
            return true
        case .chaptersOnly:
            return path.hasPrefix("docs/") && path.hasSuffix(".md")
        case .reviewsOnly:
            return path.hasPrefix("reviews/")
        case .chaptersAndReviews:
            return (path.hasPrefix("docs/") && path.hasSuffix(".md")) || path.hasPrefix("reviews/")
        }
    }
}

struct SearchPlan: Codable, Equatable {
    var summary: String
    var searches: [SearchQuery]
}

struct SearchQuery: Codable, Equatable {
    enum Method: String, Codable {
        case grep
        case searchText = "search_text"
    }

    var method: Method
    var pattern: String?
    var query: String?
    var glob: String?
    var path: String?
    var ignoreCase: Bool
    var fixedStrings: Bool
    var limit: Int
    var rationale: String

    enum CodingKeys: String, CodingKey {
        case method
        case pattern
        case query
        case glob
        case path
        case ignoreCase = "ignore_case"
        case fixedStrings = "fixed_strings"
        case limit
        case rationale
    }

    init(
        method: Method,
        pattern: String? = nil,
        query: String? = nil,
        glob: String? = nil,
        path: String? = nil,
        ignoreCase: Bool = false,
        fixedStrings: Bool = false,
        limit: Int = 50,
        rationale: String = ""
    ) {
        self.method = method
        self.pattern = pattern
        self.query = query
        self.glob = glob
        self.path = path
        self.ignoreCase = ignoreCase
        self.fixedStrings = fixedStrings
        self.limit = limit
        self.rationale = rationale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(Method.self, forKey: .method)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        glob = try container.decodeIfPresent(String.self, forKey: .glob)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        ignoreCase = try container.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        fixedStrings = try container.decodeIfPresent(Bool.self, forKey: .fixedStrings) ?? false
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
    }
}

struct ContentSearchResult: Identifiable, Equatable {
    var relativePath: String
    var lineNumber: Int
    var snippet: String
    var sourceQueryIndex: Int

    var id: String { "\(relativePath)|\(lineNumber)|\(snippet)" }
}

struct ContentSearchExecution {
    var plan: SearchPlan
    var results: [ContentSearchResult]
    var usedFallbackPlanning: Bool

    var matchCount: Int { results.count }
    var fileCount: Int { Set(results.map(\.relativePath)).count }
}
