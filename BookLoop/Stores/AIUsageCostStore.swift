import Foundation
import SwiftUI

@MainActor
final class AIUsageCostStore: ObservableObject {
    @Published private(set) var sessionEstimatedCostUSD: Double = 0
    @Published private(set) var sessionPromptTokens: Int = 0
    @Published private(set) var sessionCompletionTokens: Int = 0
    @Published private(set) var creditBalanceUSD: Double?
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var balanceLastUpdated: Date?
    @Published private(set) var balanceUnavailableReason: String?

    private let billingClient = OpenAIBillingClient()
    private var refreshTask: Task<Void, Never>?

    var hasSessionUsage: Bool {
        sessionEstimatedCostUSD > 0.000_001 || sessionPromptTokens > 0 || sessionCompletionTokens > 0
    }

    var showsBalance: Bool {
        creditBalanceUSD != nil
    }

    var showsWidget: Bool {
        showsBalance || hasSessionUsage
    }

    func resetSession() {
        sessionEstimatedCostUSD = 0
        sessionPromptTokens = 0
        sessionCompletionTokens = 0
    }

    func clearCreditBalance() {
        creditBalanceUSD = nil
        balanceUnavailableReason = nil
        balanceLastUpdated = nil
    }

    func record(usage: OpenAIUsage?, model: String, source: String) {
        guard let usage else { return }
        let prompt = usage.promptTokenCount ?? 0
        let completion = usage.completionTokenCount ?? 0
        sessionPromptTokens += prompt
        sessionCompletionTokens += completion
        sessionEstimatedCostUSD += ModelPricing.estimatedCostUSD(usage: usage, model: model)
        NSLog("BookLoop AI usage (\(source)): +\(prompt) prompt, +\(completion) completion tokens")
    }

    func scheduleBalanceRefresh(apiKey: String) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshCreditBalance(apiKey: apiKey)
        }
    }

    func refreshCreditBalance(apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            creditBalanceUSD = nil
            balanceUnavailableReason = nil
            balanceLastUpdated = nil
            return
        }

        isRefreshingBalance = true
        defer { isRefreshingBalance = false }

        if let balance = await billingClient.fetchCreditBalance(apiKey: trimmed) {
            creditBalanceUSD = balance.remainingUSD
            balanceUnavailableReason = nil
            balanceLastUpdated = Date()
        } else {
            creditBalanceUSD = nil
            balanceUnavailableReason = "Credit balance is not available for this API key. Session cost is still estimated from token usage."
            balanceLastUpdated = Date()
        }
    }
}
