import SwiftUI
import WebKit

struct BookPreviewView: View {
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var annotationStore: PreviewAnnotationStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @ObservedObject var model: BookPreviewModel
    @ObservedObject var chatModel: ChatPanelModel
    @Binding var isSidebarVisible: Bool
    @Binding var isChatVisible: Bool
    @Binding var showAnnotationsPanel: Bool

    @State private var editorError: String?
    @State private var reviewSaveMessage: String?
    @State private var reviewSaveIsError = false
    @State private var savingReviewAnnotationID: UUID?
    @State private var isSavingAllReviews = false

    var body: some View {
        VStack(spacing: 0) {
            previewToolbar
            if let hint = model.navigationHint ?? projectStore.navigationHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            Divider()
            previewBody
        }
        .onChange(of: model.autoRefreshEnabled) { _, enabled in
            model.setAutoRefreshEnabled(enabled)
        }
        .onAppear {
            model.setColorSchemeMode(settingsStore.previewColorScheme)
            annotationStore.refresh(book: model.book)
        }
        .onChange(of: model.book?.id) { _, _ in
            annotationStore.refresh(book: model.book)
            Task { await refreshAnnotations() }
        }
        .onChange(of: model.currentChapterPath) { _, _ in
            Task { await refreshAnnotations() }
        }
        .onChange(of: settingsStore.previewColorScheme) { _, mode in
            model.setColorSchemeMode(mode)
            Task { await model.applyColorSchemeToWebView() }
        }
        .sheet(isPresented: $annotationStore.isEditorPresented) {
            annotationEditorSheet
                .environmentObject(annotationStore)
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        HSplitView {
            previewContent
                .frame(minWidth: 400)

            if showAnnotationsPanel {
                annotationsPanel
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let html = model.renderedHTML, let baseURL = model.renderedBaseURL {
            WebView(
                html: html,
                baseURL: baseURL,
                contentID: model.renderContentID,
                currentURL: $model.currentURL,
                canGoBack: $model.canGoBack,
                canGoForward: $model.canGoForward,
                reloadToken: model.reloadToken,
                goBackToken: model.goBackToken,
                goForwardToken: model.goForwardToken,
                onPageLoaded: { webView in
                    Task { @MainActor in
                        model.handlePageLoaded(webView)
                        await refreshPageContext(from: webView)
                        await refreshAnnotations()
                    }
                },
                onInternalChapterLink: { url in
                    model.handleInternalLink(url)
                },
                onAnnotationClicked: { annotationID in
                    handleAnnotationClick(annotationID)
                }
            )
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Preview Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if model.book != nil {
            ContentUnavailableView {
                Label("No Chapter Loaded", systemImage: "doc.text")
            } description: {
                Text("Select a chapter from the sidebar.")
            }
        } else {
            EmptyStateView(
                title: "Select a Book",
                message: "Choose a book from the sidebar or add one.",
                systemImage: "book.fill"
            )
        }
    }

    private var annotationsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Text("\(chapterAnnotations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)

            if unsavedReviewCount > 0, model.book != nil {
                HStack {
                    Button(isSavingAllReviews ? "Saving…" : "Save All as Reviews") {
                        saveAllAnnotationsAsReviews()
                    }
                    .disabled(isSavingAllReviews || savingReviewAnnotationID != nil)
                    Spacer()
                    Text("\(unsavedReviewCount) unsaved")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            if let reviewSaveMessage {
                Text(reviewSaveMessage)
                    .font(.caption)
                    .foregroundStyle(reviewSaveIsError ? .red : .green)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider()

            if chapterAnnotations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No highlights on this chapter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Select text in the preview, then click Highlight & Note.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Save highlights or notes as reviews for the Agent to act on.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(chapterAnnotations) { annotation in
                            annotationCard(annotation)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func annotationCard(_ annotation: PreviewAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(annotation.exact)
                .font(.caption.weight(.semibold))
                .lineLimit(3)
                .foregroundStyle(.primary)

            if !annotation.note.isEmpty {
                Text(annotation.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            HStack {
                Text(DateFormatting.display.string(from: annotation.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if annotation.isSavedAsReview {
                    Label("In Reviews", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let book = model.book {
                    Button(savingReviewAnnotationID == annotation.id ? "Saving…" : "Save as Review") {
                        saveAnnotationAsReview(annotation, book: book)
                    }
                    .disabled(savingReviewAnnotationID != nil || isSavingAllReviews)
                    .font(.caption)
                }
                Button("Edit") {
                    annotationStore.beginEdit(annotation)
                }
                .font(.caption)
                if let book = model.book {
                    Button("Delete", role: .destructive) {
                        Task {
                            try? annotationStore.delete(id: annotation.id, book: book)
                            await refreshAnnotations()
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            annotationStore.selectedAnnotationID == annotation.id
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onTapGesture {
            annotationStore.selectedAnnotationID = annotation.id
        }
    }

    private var annotationEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(annotationStore.editingAnnotationID == nil ? "New Highlight" : "Edit Annotation")
                .font(.headline)

            if let quote = annotationStore.draftQuote {
                Text(quote.exact)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("Note (optional)", text: $annotationStore.draftNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)

            if let editorError {
                Text(editorError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    editorError = nil
                    annotationStore.cancelEditor()
                }
                Spacer()
                Button("Save as Review") {
                    saveDraftAsReview()
                }
                .disabled(savingReviewAnnotationID != nil)
                Button(annotationStore.editingAnnotationID == nil ? "Save Highlight" : "Save") {
                    saveAnnotation()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { isSidebarVisible.toggle() }
            } label: {
                Text(isSidebarVisible ? "Hide Panel" : "Show Panel")
            }

            Button {
                withAnimation { isChatVisible.toggle() }
            } label: {
                Text(isChatVisible ? "Hide Chat" : "Show Chat")
            }

            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button(action: model.reload) { Image(systemName: "arrow.clockwise") }

            Text(model.currentChapterPath ?? "No chapter loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Highlight & Note") {
                Task { await beginHighlightFromSelection() }
            }
            .disabled(model.book == nil || model.webView == nil)
            .help("Select text in the preview, then add a highlight and note.")

            if let editorError {
                Text(editorError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Toggle("Annotations", isOn: $showAnnotationsPanel)
                .toggleStyle(.checkbox)

            Toggle("Auto Refresh", isOn: $model.autoRefreshEnabled)
                .toggleStyle(.checkbox)

            Picker("Preview theme", selection: $settingsStore.previewColorScheme) {
                ForEach(PreviewColorSchemeMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("Preview color scheme: System follows macOS appearance, Light and Dark override it.")

            if let chapter = currentChapter {
                Button("Open Chapter") {
                    FileHelpers.openFile(path: chapter.markdownPath)
                }
            }
        }
        .padding(10)
    }

    private var chapterAnnotations: [PreviewAnnotation] {
        guard let path = model.currentChapterPath else { return [] }
        return annotationStore.annotations(for: path)
    }

    private var unsavedReviewCount: Int {
        chapterAnnotations.filter { !$0.isSavedAsReview }.count
    }

    private var currentChapter: Chapter? {
        guard let path = model.currentChapterPath else { return nil }
        return projectStore.chapters.first { $0.relativePath == path }
            ?? projectStore.chapters.first { $0.id == model.detectedChapterID }
    }

    @MainActor
    private func refreshPageContext(from webView: WKWebView) async {
        let chapterID = await WebView.detectChapterID(in: webView)
        let pageTitle = await WebView.detectPageTitle(in: webView)
        model.detectedChapterID = chapterID
        model.pageTitle = pageTitle
        chatModel.updatePageContext(chapterID: chapterID, pageTitle: pageTitle, pageURL: model.currentURL)
    }

    private func refreshAnnotations() async {
        guard let path = model.currentChapterPath else { return }
        let annotations = annotationStore.annotations(for: path)
        await model.applyAnnotations(annotations)
    }

    private func beginHighlightFromSelection() async {
        editorError = nil
        guard let quote = await model.captureSelectionQuote() else {
            editorError = PreviewAnnotationStoreError.missingSelection.errorDescription
            return
        }
        annotationStore.beginCreate(quote: quote)
    }

    private func saveAnnotation() {
        guard let book = model.book, let path = model.currentChapterPath else { return }
        do {
            _ = try annotationStore.saveDraft(
                book: book,
                chapterPath: path,
                chapterID: model.detectedChapterID
            )
            editorError = nil
            Task { await refreshAnnotations() }
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func saveDraftAsReview() {
        guard let book = model.book, let path = model.currentChapterPath else { return }
        savingReviewAnnotationID = annotationStore.editingAnnotationID ?? UUID()
        reviewSaveMessage = nil
        do {
            let response = try annotationStore.saveDraftAsReview(
                book: book,
                chapterPath: path,
                chapterID: model.detectedChapterID,
                chapters: projectStore.chapters,
                currentURL: model.currentURL,
                reviewStore: reviewStore
            )
            editorError = nil
            reviewSaveMessage = "Saved review: \(response.file)"
            reviewSaveIsError = false
            Task { await refreshAnnotations() }
        } catch {
            editorError = error.localizedDescription
            reviewSaveMessage = error.localizedDescription
            reviewSaveIsError = true
        }
        savingReviewAnnotationID = nil
    }

    private func saveAnnotationAsReview(_ annotation: PreviewAnnotation, book: BookConfig) {
        savingReviewAnnotationID = annotation.id
        reviewSaveMessage = nil
        do {
            let response = try annotationStore.saveAsReview(
                annotationID: annotation.id,
                book: book,
                chapters: projectStore.chapters,
                currentURL: model.currentURL,
                reviewStore: reviewStore
            )
            reviewSaveMessage = "Saved review: \(response.file)"
            reviewSaveIsError = false
        } catch {
            reviewSaveMessage = error.localizedDescription
            reviewSaveIsError = true
        }
        savingReviewAnnotationID = nil
    }

    private func saveAllAnnotationsAsReviews() {
        guard let book = model.book, let path = model.currentChapterPath else { return }
        isSavingAllReviews = true
        reviewSaveMessage = nil
        defer { isSavingAllReviews = false }

        let result = annotationStore.saveAllAsReviews(
            chapterPath: path,
            book: book,
            chapters: projectStore.chapters,
            currentURL: model.currentURL,
            reviewStore: reviewStore
        )

        if result.savedCount > 0, result.errors.isEmpty {
            reviewSaveMessage = "Saved \(result.savedCount) review\(result.savedCount == 1 ? "" : "s"). Open the Reviews tab to see them."
            reviewSaveIsError = false
        } else if result.savedCount > 0 {
            reviewSaveMessage = "Saved \(result.savedCount) review\(result.savedCount == 1 ? "" : "s"). \(result.errors.count) failed."
            reviewSaveIsError = true
        } else if let firstError = result.errors.first {
            reviewSaveMessage = firstError
            reviewSaveIsError = true
        } else {
            reviewSaveMessage = "No annotations to save."
            reviewSaveIsError = false
        }
    }

    private func handleAnnotationClick(_ rawID: String) {
        guard let uuid = UUID(uuidString: rawID),
              let annotation = annotationStore.annotation(id: uuid) else { return }
        annotationStore.beginEdit(annotation)
    }
}
