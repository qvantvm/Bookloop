import Foundation

final class OpenAIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendChat(apiKey: String, model: String, messages: [OpenAIChatMessage]) async throws -> OpenAIChatCompletionResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(OpenAIChatRequest(model: model, messages: messages))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIError.transportError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8)
            throw OpenAIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw OpenAIError.invalidResponse
            }
            return OpenAIChatCompletionResult(content: content, usage: decoded.usage)
        } catch let error as OpenAIError {
            throw error
        } catch {
            throw OpenAIError.decodingFailed
        }
    }

    func sendChatWithWebSearch(
        apiKey: String,
        model: String,
        instructions: String,
        input: [OpenAIChatMessage]
    ) async throws -> OpenAIChatCompletionResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw OpenAIError.invalidResponse
        }

        let body = OpenAIResponsesRequest(
            model: model,
            instructions: instructions,
            input: input,
            tools: [OpenAIResponsesTool(type: "web_search")],
            store: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIError.transportError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8)
            throw OpenAIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
            let content = decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw OpenAIError.invalidResponse
            }
            return OpenAIChatCompletionResult(content: content, usage: decoded.usage)
        } catch let error as OpenAIError {
            throw error
        } catch {
            throw OpenAIError.decodingFailed
        }
    }

    func sendChatWithTools(
        apiKey: String,
        model: String,
        messages: [OpenAIAssistantMessage],
        tools: [OpenAIToolDefinition]
    ) async throws -> OpenAIAssistantMessage {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError.missingAPIKey
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(OpenAIChatRequestWithTools(model: model, messages: messages, tools: tools))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw OpenAIError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponseWithTools.self, from: data)
        guard let message = decoded.choices.first?.message else { throw OpenAIError.invalidResponse }
        return message
    }
}
