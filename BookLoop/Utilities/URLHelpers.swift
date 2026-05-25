import Foundation

enum URLHelpers {
    static func normalizedPreviewURL(from string: String, base: URL? = nil) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            return base
        }

        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("/") {
            if let base, let scheme = base.scheme, scheme == "http" || scheme == "https" {
                var components = URLComponents()
                components.scheme = base.scheme
                components.host = base.host
                components.port = base.port
                components.path = trimmed
                return components.url
            }
            return URL(fileURLWithPath: trimmed)
        }

        if trimmed.contains("://") {
            return URL(string: trimmed)
        }

        if let base {
            return URL(string: trimmed, relativeTo: base)?.absoluteURL
        }

        return URL(string: "http://\(trimmed)")
    }

    static func inferChapterID(from url: URL?) -> String? {
        guard let url else { return nil }

        if url.scheme == "bookloop", url.host == "chapter",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            return path.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        var components = path.split(separator: "/").map(String.init)
        if components.last?.lowercased() == "index.html" {
            components.removeLast()
        }

        guard let slug = components.last, !slug.isEmpty else { return nil }
        if slug == "site" { return nil }
        if slug.hasSuffix(".md") {
            return slug.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "/", with: "-")
        }
        if slug.contains(".") { return nil }
        return slug
    }

    static func resolveDocsRelativePath(_ target: String, from currentPath: String) -> String {
        if target.hasPrefix("/") {
            return ChapterResolver.normalizedDocsRelativeMarkdownPath(String(target.dropFirst()))
        }

        var currentParts = currentPath.split(separator: "/").map(String.init)
        if currentParts.last?.hasSuffix(".md") == true {
            currentParts.removeLast()
        }

        for part in target.split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !currentParts.isEmpty { currentParts.removeLast() }
            } else {
                currentParts.append(part)
            }
        }
        return ChapterResolver.normalizedDocsRelativeMarkdownPath(currentParts.joined(separator: "/"))
    }

    static func bookloopChapterURL(for relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "bookloop"
        components.host = "chapter"
        components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        return components.url
    }
}
