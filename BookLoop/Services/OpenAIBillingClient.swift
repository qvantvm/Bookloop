import Foundation

/// Best-effort client for OpenAI prepaid credit balance.
/// The dashboard billing endpoints are undocumented and may reject API-key auth (403).
final class OpenAIBillingClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCreditBalance(apiKey: String) async -> OpenAICreditBalance? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        async let grants = fetchCreditGrants(apiKey: trimmed)
        async let pending = fetchPendingUsage(apiKey: trimmed)

        guard let grants = await grants else { return nil }
        let pendingUsage = await pending ?? 0
        return OpenAICreditBalance(availableUSD: grants, pendingUsageUSD: pendingUsage)
    }

    private func fetchCreditGrants(apiKey: String) async -> Double? {
        guard let url = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants") else {
            return nil
        }
        guard let decoded: OpenAICreditGrantsResponse = await get(url: url, apiKey: apiKey) else {
            return nil
        }

        if let total = decoded.total_available {
            return total
        }

        let grantTotal = decoded.grants?.data?.reduce(0.0) { partial, grant in
            let amount = grant.grant_amount ?? 0
            let used = grant.used_amount ?? 0
            return partial + max(0, amount - used)
        } ?? 0

        return grantTotal > 0 ? grantTotal : nil
    }

    private func fetchPendingUsage(apiKey: String) async -> Double? {
        if let url = URL(string: "https://api.openai.com/v1/dashboard/billing/pending_usage"),
           let pending: OpenAIPendingUsageResponse = await get(url: url, apiKey: apiKey),
           let usage = pending.total_usage {
            return usage
        }

        guard let usageURL = URL(string: "https://api.openai.com/v1/dashboard/billing/usage") else {
            return nil
        }
        struct UsageResponse: Decodable {
            let total_usage: Double?
        }
        let usage: UsageResponse? = await get(url: usageURL, apiKey: apiKey)
        return usage?.total_usage
    }

    private func get<T: Decodable>(url: URL, apiKey: String) async -> T? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}
