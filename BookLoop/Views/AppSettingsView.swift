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
                Text("Default model: gpt-4.1. Enter the model slug your account supports.")
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
            draftAPIKey = ""
            saveMessage = "Settings saved."
            saveIsError = false
        } catch {
            saveMessage = error.localizedDescription
            saveIsError = true
        }
    }
}
