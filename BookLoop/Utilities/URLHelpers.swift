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

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        var components = path.split(separator: "/").map(String.init)
        if components.last?.lowercased() == "index.html" {
            components.removeLast()
        }

        guard let slug = components.last, !slug.isEmpty else { return nil }
        if slug == "site" || slug.contains(".") { return nil }
        return slug
    }
}
