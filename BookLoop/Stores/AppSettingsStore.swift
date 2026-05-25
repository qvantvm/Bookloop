import SwiftUI

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var openAIModel: String = "gpt-4.1"
    @Published var hasAPIKey = false

    private(set) var apiKey: String = ""

    func load() {
        openAIModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? "gpt-4.1"
        apiKey = KeychainStore.loadOpenAIAPIKey() ?? ""
        hasAPIKey = !apiKey.isEmpty
    }

    func save(openAIModel: String, apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            try KeychainStore.saveOpenAIAPIKey(trimmedKey)
            self.apiKey = trimmedKey
            hasAPIKey = true
        }

        let trimmedModel = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIModel = trimmedModel.isEmpty ? "gpt-4.1" : trimmedModel
        UserDefaults.standard.set(self.openAIModel, forKey: Self.modelKey)
    }

    func clearAPIKey() {
        KeychainStore.deleteOpenAIAPIKey()
        apiKey = ""
        hasAPIKey = false
    }

    private static let modelKey = "bookLoop.openAIModel"
}
