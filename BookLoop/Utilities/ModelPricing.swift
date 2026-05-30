import Foundation

enum ModelPricing {
    struct Rates {
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    /// Approximate list prices (USD per 1M tokens) for session cost estimates.
    static func rates(for model: String) -> Rates {
        let normalized = model.lowercased()
        if normalized.contains("gpt-4.1-mini") || normalized.contains("gpt-4o-mini") {
            return Rates(inputPerMillion: 0.40, outputPerMillion: 1.60)
        }
        if normalized.contains("gpt-4.1") {
            return Rates(inputPerMillion: 2.00, outputPerMillion: 8.00)
        }
        if normalized.contains("gpt-4o") {
            return Rates(inputPerMillion: 2.50, outputPerMillion: 10.00)
        }
        if normalized.contains("o3-mini") {
            return Rates(inputPerMillion: 1.10, outputPerMillion: 4.40)
        }
        if normalized.contains("o1-mini") {
            return Rates(inputPerMillion: 1.10, outputPerMillion: 4.40)
        }
        if normalized.contains("o1") {
            return Rates(inputPerMillion: 15.00, outputPerMillion: 60.00)
        }
        return Rates(inputPerMillion: 2.50, outputPerMillion: 10.00)
    }

    static func estimatedCostUSD(usage: OpenAIUsage, model: String) -> Double {
        let rates = rates(for: model)
        let prompt = Double(usage.promptTokenCount ?? 0)
        let completion = Double(usage.completionTokenCount ?? 0)
        let inputCost = prompt / 1_000_000 * rates.inputPerMillion
        let outputCost = completion / 1_000_000 * rates.outputPerMillion
        return inputCost + outputCost
    }
}
