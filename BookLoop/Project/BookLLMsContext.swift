import Foundation
import Yams

enum BookLLMsContext {
    static let defaultRelativePaths = ["llms.txt", "static/llms.txt"]
    static let maxPromptCharacters = 24_000

    static func resolvePath(for book: BookConfig) -> String? {
        if let configured = book.llmsTxtPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }

        if let fromYAML = configuredRelativePath(from: book) {
            let path = book.suggestedPath(fromYAML)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        for relative in defaultRelativePaths {
            let path = book.suggestedPath(relative)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func relativePath(for book: BookConfig) -> String? {
        guard let absolute = resolvePath(for: book) else { return nil }
        let root = URL(fileURLWithPath: book.projectRootPath, isDirectory: true).standardizedFileURL.path + "/"
        let path = URL(fileURLWithPath: absolute).standardizedFileURL.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        return absolute
    }

    static func load(for book: BookConfig, generateIfMissing: Bool = false) -> String? {
        if let path = resolvePath(for: book),
           let text = readText(at: path, book: book) {
            return text
        }
        guard generateIfMissing else { return nil }
        guard let generated = try? BookLLMsTxtGenerator.write(for: book) else { return nil }
        return generated.content
    }

    @discardableResult
    static func ensureAvailable(for book: BookConfig) throws -> BookLLMsTxtGenerator.GeneratedFile? {
        if resolvePath(for: book) != nil {
            return nil
        }
        return try BookLLMsTxtGenerator.write(for: book)
    }

    static func promptExcerpt(for book: BookConfig, maxCharacters: Int = maxPromptCharacters) -> String? {
        guard let full = load(for: book, generateIfMissing: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !full.isEmpty else {
            return nil
        }
        if full.count <= maxCharacters {
            return full
        }
        return String(full.prefix(maxCharacters)) + "\n\n[llms.txt truncated for context length]"
    }

    private static func readText(at path: String, book: BookConfig) -> String? {
        try? book.withSecurityScopedProjectRoot {
            try String(contentsOfFile: path, encoding: .utf8)
        }
    }

    private static func configuredRelativePath(from book: BookConfig) -> String? {
        guard let root = BookloopYamlConfig.loadRootNode(for: book),
              case .mapping(let pairs) = root,
              let node = pairs.first(where: { nodeString($0.key) == "llms_txt" })?.value else {
            return nil
        }

        switch node {
        case .scalar(let scalar):
            return normalizeRelativePath(scalar.string)
        case .sequence(let items):
            for item in items {
                if case .scalar(let scalar) = item,
                   let path = normalizeRelativePath(scalar.string) {
                    return path
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func normalizeRelativePath(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func nodeString(_ node: Node) -> String? {
        if case .scalar(let scalar) = node {
            return scalar.string.nilIfBlank
        }
        return nil
    }
}
