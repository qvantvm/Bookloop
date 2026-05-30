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

struct OpenAIResponsesTool: Codable {
    let type: String
}

struct OpenAIResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [OpenAIChatMessage]
    let tools: [OpenAIResponsesTool]
    let store: Bool
}

struct OpenAIUsage: Codable, Equatable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
    let input_tokens: Int?
    let output_tokens: Int?

    var promptTokenCount: Int? {
        prompt_tokens ?? input_tokens
    }

    var completionTokenCount: Int? {
        completion_tokens ?? output_tokens
    }
}

struct OpenAIChatCompletionResult {
    let content: String
    let usage: OpenAIUsage?
}

struct OpenAIResponsesResponse: Decodable {
    struct OutputItem: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        let type: String
        let content: [ContentBlock]?
    }

    let output: [OutputItem]?
    let usage: OpenAIUsage?

    var outputText: String {
        guard let output else { return "" }
        var texts: [String] = []
        for item in output where item.type == "message" {
            for block in item.content ?? [] where block.type == "output_text" {
                if let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    texts.append(text)
                }
            }
        }
        return texts.joined(separator: "\n\n")
    }
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
    let usage: OpenAIUsage?
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

struct ReadingPanelLayout: Equatable {
    var isSidebarVisible = true
    var isChatVisible = true
    var isAnnotationsPanelVisible = false
}
