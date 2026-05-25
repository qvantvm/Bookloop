import Foundation
import Yams

enum BookloopYamlConfig {
    static let primaryFileNames = ["bookloop.yml", "bookloop.yaml"]
    static let legacyFileNames = ["nav.yml", "nav.yaml", "mkdocs.yml", "mkdocs.yaml"]
    static let allFileNames = primaryFileNames + legacyFileNames

    static func resolveConfigPath(for book: BookConfig) -> String? {
        if let configured = book.bookloopConfigPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }

        for name in allFileNames {
            let path = book.suggestedPath(name)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func loadRootNode(for book: BookConfig) -> Node? {
        guard let path = resolveConfigPath(for: book),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return try? Yams.compose(yaml: content)
    }

    static func legacyStatus(for path: String) -> LegacyConfigKind {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        switch name {
        case "mkdocs.yml", "mkdocs.yaml":
            return .mkdocs
        case "nav.yml", "nav.yaml":
            return .navFile
        default:
            return .none
        }
    }

    static func migrationHint(for path: String?) -> String? {
        guard let path else { return nil }
        switch legacyStatus(for: path) {
        case .mkdocs:
            return "Using mkdocs.yml. Create bookloop.yml at the book root."
        case .navFile:
            return "Rename nav.yml to bookloop.yml (BookLoop project config)."
        case .none:
            return nil
        }
    }

    static func createBookloopYAML(fromLegacyMkDocsAt path: String) throws -> String {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        guard let root = try Yams.compose(yaml: content), case .mapping(let pairs) = root else {
            throw BookloopYamlConfigError.invalidFormat
        }

        var extracted: [String: Any] = [:]
        let keys = ["site_name", "site_description", "site_author", "theme", "extra_css", "nav", "markdown_extensions"]
        for key in keys {
            if let pair = pairs.first(where: { nodeString($0.key) == key }),
               let value = yamlObject(from: pair.value) {
                extracted[key] = value
            }
        }

        guard extracted["nav"] != nil else {
            throw BookloopYamlConfigError.navSectionMissing
        }

        let body = try Yams.dump(object: extracted)
        return "# BookLoop project config\n# Migrated from mkdocs.yml\n\n" + body
    }

    private static func yamlObject(from node: Node) -> Any? {
        switch node {
        case .scalar(let scalar):
            return scalar.string
        case .sequence(let items):
            return items.compactMap { yamlObject(from: $0) }
        case .mapping(let pairs):
            var dict: [String: Any] = [:]
            for pair in pairs {
                guard let key = nodeString(pair.key), let value = yamlObject(from: pair.value) else { continue }
                dict[key] = value
            }
            return dict
        case .alias:
            return nil
        }
    }

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}

enum LegacyConfigKind: Equatable {
    case none
    case navFile
    case mkdocs
}

enum BookloopYamlConfigError: LocalizedError {
    case invalidFormat
    case navSectionMissing

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Project config could not be parsed."
        case .navSectionMissing:
            return "Project config is missing a nav: section."
        }
    }
}

typealias BookProjectYamlConfig = BookloopYamlConfig
