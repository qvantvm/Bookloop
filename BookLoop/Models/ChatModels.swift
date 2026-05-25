import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct PageChatContext: Equatable {
    var pageKey: String
    var chapterID: String
    var pageTitle: String?
    var pageURL: String?
}

struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [OpenAIChatMessage]
}

struct OpenAIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String?)
    case decodingFailed
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured. Open Settings to add your key."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .httpError(let statusCode, let body):
            if let body, !body.isEmpty { return "OpenAI HTTP \(statusCode): \(body)" }
            return "OpenAI HTTP \(statusCode)"
        case .decodingFailed:
            return "Failed to decode the OpenAI response."
        case .transportError(let message):
            return message
        }
    }
}

enum PageChatKey {
    static func make(chapterID: String?, pageURL: URL?) -> String {
        if let chapterID, !chapterID.isEmpty {
            return "chapter:\(chapterID)"
        }
        if let pageURL {
            return "url:\(pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
        return "unknown"
    }
}

enum WorkspaceMode: Equatable {
    case reading
    case tool(WorkspaceTab)
}
