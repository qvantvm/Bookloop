import Foundation

struct AgentURLFetchResult: Encodable {
    var url: String
    var fetchedURL: String
    var statusCode: Int
    var contentType: String?
    var body: String
    var truncated: Bool
    var bytesReturned: Int
    var maxBytes: Int
}

enum AgentURLFetcherError: LocalizedError {
    case invalidURL
    case blockedHost(String)
    case nonHTTPS
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL. Use a full https:// URL."
        case .blockedHost(let host):
            return "Blocked host: \(host). Only public HTTPS URLs are allowed."
        case .nonHTTPS:
            return "Only HTTPS URLs are allowed."
        case .requestFailed(let message):
            return "Fetch failed: \(message)"
        case .emptyResponse:
            return "The response body was empty."
        }
    }
}

enum AgentURLFetcher {
    static let defaultMaxBytes = 65_536
    static let minMaxBytes = 8_192
    static let maxMaxBytes = 524_288
    static let requestTimeoutSeconds: TimeInterval = 30

    static func fetch(urlString: String, maxBytes: Int, session: URLSession = .shared) async throws -> AgentURLFetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let initialURL = URL(string: trimmed), initialURL.scheme?.lowercased() == "https" else {
            throw AgentURLFetcherError.nonHTTPS
        }
        try validateHost(initialURL)

        let cappedMax = min(max(maxBytes, minMaxBytes), maxMaxBytes)
        let candidates = preferredURLs(for: initialURL)
        var lastError: Error?

        for candidate in candidates {
            do {
                return try await fetchSingle(url: candidate, originalURL: trimmed, maxBytes: cappedMax, session: session)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AgentURLFetcherError.requestFailed("No response")
    }

    private static func fetchSingle(
        url: URL,
        originalURL: String,
        maxBytes: Int,
        session: URLSession
    ) async throws -> AgentURLFetchResult {
        try validateHost(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("BookLoop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain,application/json,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentURLFetcherError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AgentURLFetcherError.requestFailed("HTTP \(http.statusCode)")
        }

        let truncated = data.count > maxBytes
        let payload = truncated ? Data(data.prefix(maxBytes)) : data
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        let body = decodeBody(data: payload, contentType: contentType)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentURLFetcherError.emptyResponse
        }

        return AgentURLFetchResult(
            url: originalURL,
            fetchedURL: url.absoluteString,
            statusCode: http.statusCode,
            contentType: contentType,
            body: body,
            truncated: truncated,
            bytesReturned: payload.count,
            maxBytes: maxBytes
        )
    }

    private static func preferredURLs(for url: URL) -> [URL] {
        guard url.host?.lowercased() == "github.com" else { return [url] }

        let parts = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return [url] }

        let owner = parts[0]
        let repo = parts[1]

        if parts.count == 2 {
            return [
                URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/README.md"),
                URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/master/README.md"),
                url
            ].compactMap { $0 }
        }

        if parts.count >= 5, parts[2] == "blob" {
            let branch = parts[3]
            let filePath = parts.dropFirst(4).joined(separator: "/")
            if let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(filePath)") {
                return [raw, url]
            }
        }

        return [url]
    }

    private static func validateHost(_ url: URL) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw AgentURLFetcherError.invalidURL
        }

        if host == "localhost" || host.hasSuffix(".local") || host == "0.0.0.0" {
            throw AgentURLFetcherError.blockedHost(host)
        }

        if host == "::1" || host.hasPrefix("127.") {
            throw AgentURLFetcherError.blockedHost(host)
        }

        if host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            throw AgentURLFetcherError.blockedHost(host)
        }

        if host.hasPrefix("172.") {
            let octets = host.split(separator: ".")
            if octets.count >= 2, let second = Int(octets[1]), (16...31).contains(second) {
                throw AgentURLFetcherError.blockedHost(host)
            }
        }

        if host == "[::1]" {
            throw AgentURLFetcherError.blockedHost(host)
        }
    }

    private static func decodeBody(data: Data, contentType: String?) -> String {
        let lowered = contentType?.lowercased() ?? ""
        let raw: String
        if let utf8 = String(data: data, encoding: .utf8) {
            raw = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            raw = latin1
        } else {
            raw = data.base64EncodedString()
            return "[binary content, base64]\n\(raw)"
        }

        if lowered.contains("html") {
            return simplifyHTML(raw)
        }
        return raw
    }

    private static func simplifyHTML(_ html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            (#"(?is)<script.*?>.*?</script>"#, "\n"),
            (#"(?is)<style.*?>.*?</style>"#, "\n"),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|section|article|li|h[1-6]|tr)>"#, "\n"),
            (#"(?is)<[^>]+>"#, " ")
        ]
        for (pattern, replacement) in patterns {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }
}
