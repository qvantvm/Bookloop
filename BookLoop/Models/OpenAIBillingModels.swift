import Foundation

struct OpenAICreditGrantsResponse: Decodable {
    struct Grants: Decodable {
        struct Grant: Decodable {
            let grant_amount: Double?
            let used_amount: Double?
            let effective_at: Double?
            let expires_at: Double?
        }

        let data: [Grant]?
    }

    let grants: Grants?
    let total_available: Double?
    let total_used: Double?
}

struct OpenAIPendingUsageResponse: Decodable {
    let total_usage: Double?
}

struct OpenAICreditBalance: Equatable {
    let availableUSD: Double
    let pendingUsageUSD: Double

    var remainingUSD: Double {
        max(0, availableUSD - pendingUsageUSD)
    }
}
