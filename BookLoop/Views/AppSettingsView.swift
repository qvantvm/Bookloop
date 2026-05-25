import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @State private var draftModel = "gpt-4.1"
    @State private var draftAPIKey = ""
    @State private var saveMessage: String?
    @State private var saveIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Settings")
                .font(.title2.bold())

            Form {
                TextField("OpenAI Model", text: $draftModel)
                SecureField(settingsStore.hasAPIKey ? "OpenAI API Key (saved)" : "OpenAI API Key", text: $draftAPIKey)

                Section("Preview") {
                    Picker("Chapter preview theme", selection: $settingsStore.previewColorScheme) {
                        ForEach(PreviewColorSchemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows macOS light/dark mode. Light and Dark override it for the chapter preview only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Native Agent") {
                    Stepper("Max tool iterations: \(settingsStore.maxAgentIterations)", value: $settingsStore.maxAgentIterations, in: 1...40)
                    Stepper("Build timeout (seconds): \(settingsStore.buildTimeoutSeconds)", value: $settingsStore.buildTimeoutSeconds, in: 30...600, step: 30)
                    Toggle("Allow agent to edit review items", isOn: $settingsStore.allowAgentReviewEdits)
                    Toggle("Auto-run build after patch apply", isOn: $settingsStore.autoRunBuildAfterAgent)
                }

                Text("Default model: gpt-4.1 (change to any OpenAI chat model you have access to). No web search — the agent only reads your book repo via local tools. For long reviews, raise max iterations (default 20) or run Apply Review Feedback again after applying the first patch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(saveIsError ? .red : .green)
            }

            HStack {
                if settingsStore.hasAPIKey {
                    Button("Remove Key") {
                        settingsStore.clearAPIKey()
                        draftAPIKey = ""
                        saveMessage = "API key removed."
                        saveIsError = false
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Save") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear {
            draftModel = settingsStore.openAIModel
        }
    }

    private func saveSettings() {
        do {
            try settingsStore.save(openAIModel: draftModel, apiKey: draftAPIKey)
            settingsStore.saveAgentSettings()
            draftAPIKey = ""
            saveMessage = "Settings saved. Your API key is stored locally for this Mac user account."
            saveIsError = false
        } catch {
            saveMessage = error.localizedDescription
            saveIsError = true
        }
    }
}
