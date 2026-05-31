import Foundation

struct OpenAIToolDefinition: Codable, Equatable {
    let type: String
    let function: OpenAIFunctionDefinition

    static func function(name: String, description: String, parameters: OpenAIFunctionParameters) -> OpenAIToolDefinition {
        OpenAIToolDefinition(type: "function", function: OpenAIFunctionDefinition(name: name, description: description, parameters: parameters))
    }
}

struct OpenAIJSONSchemaProperty: Codable, Equatable {
    let type: String
    let description: String
}

struct OpenAIFunctionParameters: Codable, Equatable {
    let type: String
    let properties: [String: OpenAIJSONSchemaProperty]
    let required: [String]

    static func object(properties: [String: OpenAIJSONSchemaProperty], required: [String] = []) -> OpenAIFunctionParameters {
        OpenAIFunctionParameters(type: "object", properties: properties, required: required)
    }
}

struct OpenAIFunctionDefinition: Codable, Equatable {
    let name: String
    let description: String
    let parameters: OpenAIFunctionParameters
}

struct OpenAIToolCall: Codable, Equatable {
    let id: String
    let type: String
    let function: OpenAIFunctionCall
}

struct OpenAIFunctionCall: Codable, Equatable {
    let name: String
    let arguments: String
}

enum OpenAIMessageContent: Codable, Equatable {
    case text(String)
    case parts([OpenAIMessageContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .parts(try container.decode([OpenAIMessageContentPart].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    var textValue: String? {
        switch self {
        case .text(let string): return string
        case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
        }
    }

    func contains(_ substring: String) -> Bool {
        textValue?.contains(substring) ?? false
    }
}

struct OpenAIMessageContentPart: Codable, Equatable {
    let type: String
    var text: String?
    var image_url: OpenAIImageURLPayload?

    static func text(_ value: String) -> OpenAIMessageContentPart {
        OpenAIMessageContentPart(type: "text", text: value, image_url: nil)
    }

    static func imageDataURL(_ url: String, detail: String = "high") -> OpenAIMessageContentPart {
        OpenAIMessageContentPart(type: "image_url", text: nil, image_url: OpenAIImageURLPayload(url: url, detail: detail))
    }
}

struct OpenAIImageURLPayload: Codable, Equatable {
    let url: String
    let detail: String?
}

struct OpenAIAssistantMessage: Codable, Equatable {
    let role: String
    let content: OpenAIMessageContent?
    let tool_calls: [OpenAIToolCall]?
    let tool_call_id: String?

    init(role: String, content: String?, tool_calls: [OpenAIToolCall]?, tool_call_id: String?) {
        self.role = role
        self.content = content.map { .text($0) }
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    init(role: String, contentParts: [OpenAIMessageContentPart], tool_calls: [OpenAIToolCall]?, tool_call_id: String?) {
        self.role = role
        self.content = .parts(contentParts)
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
}

struct OpenAIChatRequestWithTools: Codable {
    let model: String
    let messages: [OpenAIAssistantMessage]
    let tools: [OpenAIToolDefinition]?
}

struct OpenAIToolCompletionResult {
    let message: OpenAIAssistantMessage
    let usage: OpenAIUsage?
}

struct OpenAIChatResponseWithTools: Codable {
    struct Choice: Codable {
        let message: OpenAIAssistantMessage
        let finish_reason: String?
    }
    let choices: [Choice]
    let usage: OpenAIUsage?
}

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let array = try? container.decode([AnyCodable].self) { value = array.map(\.value) }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String: try container.encode(string)
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let array as [Any]: try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encode(String(describing: value))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
