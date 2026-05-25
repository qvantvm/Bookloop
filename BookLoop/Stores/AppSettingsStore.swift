import SwiftUI

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var openAIModel: String = "gpt-4.1"
    @Published var hasAPIKey = false
    @Published var maxAgentIterations: Int = 20
    @Published var buildTimeoutSeconds: Int = 120
    @Published var allowAgentReviewEdits: Bool = false
    @Published var autoRunBuildAfterAgent: Bool = true

    private(set) var apiKey: String = ""

    func load() {
        openAIModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? "gpt-4.1"
        maxAgentIterations = UserDefaults.standard.object(forKey: Self.maxIterationsKey) as? Int ?? 20
        buildTimeoutSeconds = UserDefaults.standard.object(forKey: Self.buildTimeoutKey) as? Int ?? 120
        allowAgentReviewEdits = UserDefaults.standard.bool(forKey: Self.allowReviewEditsKey)
        autoRunBuildAfterAgent = UserDefaults.standard.object(forKey: Self.autoBuildKey) as? Bool ?? true
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
        persistAgentSettings()
    }

    func saveAgentSettings() {
        persistAgentSettings()
    }

    func clearAPIKey() {
        KeychainStore.deleteOpenAIAPIKey()
        apiKey = ""
        hasAPIKey = false
    }

    private func persistAgentSettings() {
        UserDefaults.standard.set(maxAgentIterations, forKey: Self.maxIterationsKey)
        UserDefaults.standard.set(buildTimeoutSeconds, forKey: Self.buildTimeoutKey)
        UserDefaults.standard.set(allowAgentReviewEdits, forKey: Self.allowReviewEditsKey)
        UserDefaults.standard.set(autoRunBuildAfterAgent, forKey: Self.autoBuildKey)
    }

    private static let modelKey = "bookLoop.openAIModel"
    private static let maxIterationsKey = "bookLoop.maxAgentIterations"
    private static let buildTimeoutKey = "bookLoop.buildTimeoutSeconds"
    private static let allowReviewEditsKey = "bookLoop.allowAgentReviewEdits"
    private static let autoBuildKey = "bookLoop.autoRunBuildAfterAgent"
}
