import Foundation

enum TokenEstimator {
    /// Rough OpenAI token estimate (~4 characters per token for English text).
    static func estimateTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    static func estimateTokens(for messages: [OpenAIChatMessage]) -> Int {
        guard !messages.isEmpty else { return 0 }
        var total = 2
        for message in messages {
            total += 4
            total += estimateTokens(in: message.content)
        }
        return total
    }

    static func estimateTokens(instructions: String, input: [OpenAIChatMessage]) -> Int {
        estimateTokens(in: instructions) + estimateTokens(for: input)
    }
}
