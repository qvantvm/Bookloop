import AppKit
import SwiftUI

struct AddFigurePrefill: Equatable {
    var figureID: String?
    var chapterID: String?
    var caption: String?
    var altText: String?
    var targetMarkdownPath: String?
    var sourceKind: FigureSourceKind?
}

struct AddFigureSheet: View {
    let book: BookConfig
    var prefill: AddFigurePrefill = AddFigurePrefill()
    var onPatchBuilt: (URL) -> Void

    @EnvironmentObject private var bookProjectStore: BookProjectStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @Environment(\.dismiss) private var dismiss

    @State private var tab: FigureSourceKind = .upload
    @State private var draft: FigureProposalDraft
    @State private var uploadData: Data?
    @State private var uploadExtension = "png"
    @State private var uploadPreviewPath: String?
    @State private var urlString = ""
    @State private var scriptBody = ""
    @State private var scriptCommand = ""
    @State private var scriptPreviewPath: String?
    @State private var scriptSourceFiles: [FigureStagedFile] = []
    @State private var placementSuggestionText = ""
    @State private var placementToolLog: [AgentToolLogEntry] = []
    @State private var showPlacementToolLog = false
    @State private var statusMessage: String?
    @State private var isWorking = false

    init(book: BookConfig, prefill: AddFigurePrefill = AddFigurePrefill(), onPatchBuilt: @escaping (URL) -> Void) {
        self.book = book
        self.prefill = prefill
        self.onPatchBuilt = onPatchBuilt

        var initial = FigureProposalDraft.empty(book: book)
        if let figureID = prefill.figureID?.nilIfBlank { initial.id = figureID }
        if let chapterID = prefill.chapterID?.nilIfBlank { initial.chapterID = chapterID }
        if let caption = prefill.caption?.nilIfBlank { initial.caption = caption }
        if let altText = prefill.altText?.nilIfBlank { initial.altText = altText }
        if let path = prefill.targetMarkdownPath?.nilIfBlank { initial.targetMarkdownPath = path }
        if let kind = prefill.sourceKind { initial.sourceKind = kind }

        _draft = State(initialValue: initial)
        _tab = State(initialValue: prefill.sourceKind ?? .upload)
        _urlString = State(initialValue: "")
        _scriptBody = State(initialValue: FigureScriptRunner.defaultScript(for: prefill.sourceKind ?? .mermaid, figureID: initial.id))
        _scriptCommand = State(initialValue: FigureScriptRunner.defaultCommand(for: prefill.sourceKind ?? .mermaid, book: book))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataFields
                    sourceTabs
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 560)
        .onChange(of: tab) { _, newTab in
            draft.sourceKind = newTab
            if scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scriptBody = FigureScriptRunner.defaultScript(for: newTab, figureID: draft.id)
            }
            if scriptCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scriptCommand = FigureScriptRunner.defaultCommand(for: newTab, book: book)
            }
        }
        .onChange(of: draft.id) { _, newID in
            if tab == .mermaid || tab == .jsScript || tab == .pythonScript {
                if scriptBody.contains("figure-") || scriptBody.contains(draft.id) == false {
                    scriptBody = FigureScriptRunner.defaultScript(for: tab, figureID: newID)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Add Figure")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button("Cancel") { dismiss() }
        }
        .padding()
    }

    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Figure metadata")
                .font(.headline)
            TextField("Figure ID", text: $draft.id)
            TextField("Chapter ID (optional)", text: Binding(get: { draft.chapterID ?? "" }, set: { draft.chapterID = $0.nilIfBlank }))
            TextField("Caption", text: $draft.caption)
            TextField("Alt text", text: $draft.altText)
            TextField("Target markdown path (optional)", text: Binding(get: { draft.targetMarkdownPath ?? "" }, set: { draft.targetMarkdownPath = $0.nilIfBlank }))
            Toggle("Insert markdown image reference in chapter", isOn: $draft.insertMarkdown)
            if draft.insertMarkdown {
                placementSection
            }
        }
    }

    @ViewBuilder
    private var placementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI placement")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Describe where the figure should go. AI will inspect chapters with read/grep tools and propose the best anchor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Placement suggestion", text: $placementSuggestionText, axis: .vertical)
                .lineLimit(3...6)
                .onChange(of: placementSuggestionText) { _, newValue in
                    draft.placementSuggestion = newValue.nilIfBlank
                }
            HStack {
                Button(isWorking ? "Placing…" : "Ask AI to place") {
                    Task { await askAIPlacement() }
                }
                .disabled(isWorking || !canAskAIPlacement)
                if draft.aiPlacement != nil {
                    Button("Clear AI placement") {
                        clearAIPlacement()
                    }
                }
            }
            if !settingsStore.hasAPIKey {
                Text("Add an OpenAI API key in App Settings to use AI placement.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let placement = draft.aiPlacement {
                GroupBox("Proposed placement") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("File", value: placement.markdownPath)
                        if let section = placement.sectionHeading?.nilIfBlank {
                            LabeledContent("Section", value: section)
                        }
                        if let rationale = placement.rationale?.nilIfBlank {
                            Text(rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("Insert mode: \(placement.insertMode.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !placementToolLog.isEmpty {
                DisclosureGroup(isExpanded: $showPlacementToolLog) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(placementToolLog) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.toolName) • \(entry.succeeded ? "ok" : "failed")")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(entry.resultSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } label: {
                    Text("Placement tool log (\(placementToolLog.count))")
                        .font(.caption)
                }
            }
        }
        .padding(.top, 4)
    }

    private var canAskAIPlacement: Bool {
        uploadData != nil
            && placementSuggestionText.nilIfBlank != nil
            && settingsStore.hasAPIKey
    }

    private var sourceTabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)
            Picker("Source", selection: $tab) {
                Text("Upload").tag(FigureSourceKind.upload)
                Text("From URL").tag(FigureSourceKind.urlImport)
                Text("Mermaid").tag(FigureSourceKind.mermaid)
                Text("JavaScript").tag(FigureSourceKind.jsScript)
                Text("Python").tag(FigureSourceKind.pythonScript)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .upload:
                uploadTab
            case .urlImport:
                urlTab
            case .mermaid, .jsScript, .pythonScript:
                scriptTab
            default:
                Text("This source is not available in Phase 1.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var uploadTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Image…") { pickUploadFile() }
                    .disabled(isWorking)
                if uploadData != nil {
                    Text("\(uploadData?.count ?? 0) bytes • .\(uploadExtension)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let uploadPreviewPath {
                FigurePreview(path: uploadPreviewPath, type: previewType(for: uploadExtension))
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private var urlTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("HTTPS image URL", text: $urlString)
            TextField("Attribution (optional)", text: Binding(get: { draft.attribution ?? "" }, set: { draft.attribution = $0.nilIfBlank }))
            HStack {
                Button(isWorking ? "Fetching…" : "Fetch Preview") {
                    Task { await fetchURLPreview() }
                }
                .disabled(isWorking || urlString.nilIfBlank == nil)
            }
            if let uploadPreviewPath {
                FigurePreview(path: uploadPreviewPath, type: previewType(for: uploadExtension))
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private var scriptTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !book.allowShellCommands || !book.allowFigureRegeneration {
                Text("Enable Allow shell commands and Allow figure regeneration in book Settings to preview scripts.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextField("Generation command", text: $scriptCommand)
                .font(.system(.body, design: .monospaced))
            TextEditor(text: $scriptBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Button(isWorking ? "Running…" : "Preview Script") {
                    Task { await previewScript() }
                }
                .disabled(isWorking || !book.allowShellCommands || !book.allowFigureRegeneration)
            }
            if let scriptPreviewPath {
                FigurePreview(path: scriptPreviewPath, type: .png)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Build Patch writes to bookloop/patches/ only. Apply from the Patches tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isWorking ? "Building…" : "Build Patch") {
                Task { await buildPatch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || !canBuildPatch)
        }
        .padding()
    }

    private var canBuildPatch: Bool {
        guard draft.id.nilIfBlank != nil else { return false }
        switch tab {
        case .upload:
            return uploadData != nil
        case .urlImport:
            return uploadData != nil
        case .mermaid, .jsScript, .pythonScript:
            return scriptPreviewPath != nil && uploadData != nil
        default:
            return false
        }
    }

    private func pickUploadFile() {
        guard let path = PathPicker.pickFile(title: "Choose figure image", initialPath: book.projectRootPath) else { return }
        do {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                statusMessage = "Selected file is empty."
                return
            }
            uploadData = data
            uploadExtension = normalizedExtension(url.pathExtension)
            uploadPreviewPath = url.path
            draft.sourceKind = .upload
            statusMessage = "Loaded \(url.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func fetchURLPreview() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await FigureAssetFetcher.fetchImage(urlString: urlString)
            uploadData = result.data
            uploadExtension = result.suggestedExtension
            draft.sourceKind = .urlImport
            draft.sourceURL = result.sourceURL
            let previewURL = writeTemporaryPreview(data: result.data, ext: result.suggestedExtension)
            uploadPreviewPath = previewURL?.path
            statusMessage = "Fetched \(result.data.count) bytes from URL."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func previewScript() async {
        isWorking = true
        defer { isWorking = false }
        do {
            draft.sourceKind = tab
            draft.generationCommand = scriptCommand.nilIfBlank
            let preview = try await FigureScriptRunner.preview(
                draft: draft,
                book: book,
                scriptBody: scriptBody,
                command: scriptCommand
            )
            let data = try Data(contentsOf: URL(fileURLWithPath: preview.outputAbsolutePath))
            uploadData = data
            uploadExtension = URL(fileURLWithPath: preview.outputRelativePath).pathExtension.nilIfBlank ?? "png"
            scriptPreviewPath = preview.outputAbsolutePath
            scriptSourceFiles = preview.sourceRelativePaths.map {
                FigureStagedFile(
                    relativePath: $0,
                    oldText: nil,
                    newText: scriptBody,
                    newData: nil
                )
            }
            statusMessage = "Script preview succeeded."
            if !preview.commandOutput.isEmpty {
                statusMessage? += "\n\(preview.commandOutput)"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func buildPatch() async {
        guard let assetData = uploadData else {
            statusMessage = "No figure asset is ready."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            draft.sourceKind = tab
            draft.placementSuggestion = placementSuggestionText.nilIfBlank
            if tab == .urlImport {
                draft.sourceURL = urlString.nilIfBlank ?? draft.sourceURL
            }
            if tab == .mermaid || tab == .jsScript || tab == .pythonScript {
                draft.generationCommand = scriptCommand.nilIfBlank
            }

            var extraSources = scriptSourceFiles
            if extraSources.isEmpty, tab == .mermaid || tab == .jsScript || tab == .pythonScript {
                let ext: String
                switch tab {
                case .mermaid: ext = "mmd"
                case .jsScript: ext = "js"
                case .pythonScript: ext = "py"
                default: ext = "txt"
                }
                extraSources = [
                    FigureStagedFile(
                        relativePath: "figures/\(draft.id)/source.\(ext)",
                        oldText: nil,
                        newText: scriptBody,
                        newData: nil
                    )
                ]
            }

            let result = try FigurePatchBuilder().build(
                book: book,
                draft: draft,
                assetData: assetData,
                assetExtension: uploadExtension,
                extraSourceFiles: extraSources
            )
            statusMessage = "Created patch \(result.patchURL.lastPathComponent)"
            onPatchBuilt(result.patchURL)
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func askAIPlacement() async {
        guard let assetData = uploadData else {
            statusMessage = FigurePlacementError.missingAsset.localizedDescription
            return
        }
        guard placementSuggestionText.nilIfBlank != nil else {
            statusMessage = FigurePlacementError.missingSuggestion.localizedDescription
            return
        }
        guard settingsStore.hasAPIKey else {
            statusMessage = FigurePlacementError.missingAPIKey.localizedDescription
            return
        }

        isWorking = true
        defer { isWorking = false }

        if bookProjectStore.project == nil {
            bookProjectStore.refresh(book: book, currentChapterID: draft.chapterID)
        }
        guard let project = bookProjectStore.project else {
            statusMessage = FigurePlacementError.missingProject.localizedDescription
            return
        }

        draft.placementSuggestion = placementSuggestionText.nilIfBlank
        placementToolLog = []
        statusMessage = "Asking AI to find the best placement…"

        do {
            let result = try await FigurePlacementPlanner().plan(
                book: book,
                project: project,
                searchIndex: bookProjectStore.searchIndex,
                chapterNav: projectStore.chapterNav,
                draft: draft,
                imageData: assetData,
                imageExtension: uploadExtension,
                apiKey: settingsStore.apiKey,
                model: settingsStore.openAIModel
            )
            draft.aiPlacement = result.placement
            draft.targetMarkdownPath = result.placement.markdownPath
            if let caption = result.placement.suggestedCaption?.nilIfBlank {
                draft.caption = caption
            }
            if let alt = result.placement.suggestedAltText?.nilIfBlank {
                draft.altText = alt
            }
            placementToolLog = result.toolLog
            showPlacementToolLog = !result.toolLog.isEmpty
            if let summary = result.summary?.nilIfBlank {
                statusMessage = "AI placement ready.\n\(summary)"
            } else {
                statusMessage = "AI placement ready in \(result.placement.markdownPath)."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func clearAIPlacement() {
        draft.aiPlacement = nil
        placementToolLog = []
        showPlacementToolLog = false
        statusMessage = "Cleared AI placement. Manual target path is used again."
    }

    private func writeTemporaryPreview(data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookloop-figure-preview-\(UUID().uuidString).\(ext)")
        try? data.write(to: url)
        return url
    }

    private func normalizedExtension(_ raw: String) -> String {
        let ext = raw.lowercased()
        if ext == "jpeg" { return "jpg" }
        if ["png", "jpg", "svg", "gif", "pdf", "webp"].contains(ext) { return ext }
        return "png"
    }

    private func previewType(for ext: String) -> FigureType {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        case "svg": return .svg
        default: return .unknown
        }
    }
}
