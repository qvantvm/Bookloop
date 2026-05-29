import Foundation

@MainActor
final class PreviewAnnotationStore: ObservableObject {
    @Published private(set) var annotations: [PreviewAnnotation] = []
    @Published var selectedAnnotationID: UUID?
    @Published var hoveredAnnotationID: UUID?
    @Published var isEditorPresented = false
    @Published var draftNote = ""
    @Published var draftQuote: PreviewSelectionQuote?
    @Published var editingAnnotationID: UUID?
    @Published var draftHighlightID: UUID?
    @Published var lastError: String?

    private var loadedBookID: UUID?

    static let fileName = "preview_annotations.json"

    var fileRelativePath: String { ".bookloop/\(Self.fileName)" }

    func refresh(book: BookConfig?) {
        guard let book else {
            annotations = []
            loadedBookID = nil
            return
        }

        let previousBookID = loadedBookID
        loadedBookID = book.id

        do {
            let loaded = try loadDocument(book: book)
            annotations = loaded.annotations.map { normalizePaths($0) }
            if !annotations.isEmpty,
               !FileManager.default.fileExists(atPath: Self.appSupportFileURL(bookID: book.id).path) {
                try persist(book: book)
            }
            lastError = nil
        } catch {
            if previousBookID != book.id {
                annotations = []
            }
            lastError = error.localizedDescription
        }
    }

    func annotations(for chapterPath: String) -> [PreviewAnnotation] {
        let normalized = normalizedChapterPath(chapterPath)
        return annotations
            .filter { normalizedChapterPath($0.chapterPath) == normalized }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func annotation(id: UUID) -> PreviewAnnotation? {
        annotations.first { $0.id == id }
    }

    func beginCreate(quote: PreviewSelectionQuote) {
        draftQuote = quote
        draftNote = ""
        editingAnnotationID = nil
        draftHighlightID = UUID()
        isEditorPresented = true
    }

    func beginEdit(_ annotation: PreviewAnnotation) {
        draftQuote = annotation.quote
        draftNote = annotation.note
        editingAnnotationID = annotation.id
        draftHighlightID = nil
        selectedAnnotationID = annotation.id
        isEditorPresented = true
    }

    func cancelEditor() {
        isEditorPresented = false
        draftQuote = nil
        draftNote = ""
        editingAnnotationID = nil
        draftHighlightID = nil
    }

    @discardableResult
    func saveDraft(
        book: BookConfig,
        chapterPath: String,
        chapterID: String?
    ) throws -> PreviewAnnotation {
        guard let quote = draftQuote else {
            throw PreviewAnnotationStoreError.missingSelection
        }
        let trimmedExact = quote.exact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExact.isEmpty else {
            throw PreviewAnnotationStoreError.missingSelection
        }

        let now = Date()
        let normalizedPath = normalizedChapterPath(chapterPath)
        let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved: PreviewAnnotation
        if let editingAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == editingAnnotationID }) {
            var updated = annotations[index]
            updated.exact = trimmedExact
            updated.prefix = quote.prefix
            updated.suffix = quote.suffix
            updated.note = note
            updated.chapterPath = normalizedPath
            updated.chapterID = chapterID
            updated.updatedAt = now
            annotations[index] = updated
            saved = updated
        } else {
            let created = PreviewAnnotation(
                id: UUID(),
                chapterPath: normalizedPath,
                chapterID: chapterID,
                exact: trimmedExact,
                prefix: quote.prefix,
                suffix: quote.suffix,
                note: note,
                createdAt: now,
                updatedAt: now
            )
            annotations.append(created)
            saved = created
        }

        try persist(book: book)
        selectedAnnotationID = saved.id
        isEditorPresented = false
        draftQuote = nil
        draftNote = ""
        editingAnnotationID = nil
        draftHighlightID = nil
        lastError = nil
        return saved
    }

    func delete(id: UUID, book: BookConfig) throws {
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id {
            selectedAnnotationID = nil
        }
        if hoveredAnnotationID == id {
            hoveredAnnotationID = nil
        }
        try persist(book: book)
    }

    @discardableResult
    func saveAsReview(
        annotationID: UUID,
        book: BookConfig,
        chapters: [Chapter],
        currentURL: URL?,
        reviewStore: ReviewStore
    ) throws -> ReviewResponse {
        guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else {
            throw PreviewAnnotationStoreError.annotationNotFound
        }
        var annotation = annotations[index]
        if annotation.isSavedAsReview {
            throw PreviewAnnotationStoreError.alreadySavedAsReview
        }

        let request = AnnotationReviewConverter.reviewRequest(
            for: annotation,
            book: book,
            chapters: chapters,
            currentURL: currentURL
        )
        let response = try ReviewItemWriter().write(request: request, book: book)

        annotation.savedReviewID = response.id
        annotation.savedReviewFile = response.file
        annotations[index] = annotation
        try persist(book: book)
        reviewStore.refresh(book: book)
        lastError = nil
        return response
    }

    @discardableResult
    func saveDraftAsReview(
        book: BookConfig,
        chapterPath: String,
        chapterID: String?,
        chapters: [Chapter],
        currentURL: URL?,
        reviewStore: ReviewStore
    ) throws -> ReviewResponse {
        let saved = try saveDraft(book: book, chapterPath: chapterPath, chapterID: chapterID)
        if saved.isSavedAsReview {
            throw PreviewAnnotationStoreError.alreadySavedAsReview
        }
        return try saveAsReview(
            annotationID: saved.id,
            book: book,
            chapters: chapters,
            currentURL: currentURL,
            reviewStore: reviewStore
        )
    }

    func saveAllAsReviews(
        chapterPath: String,
        book: BookConfig,
        chapters: [Chapter],
        currentURL: URL?,
        reviewStore: ReviewStore
    ) -> AnnotationReviewBatchResult {
        let candidates = annotations(for: chapterPath).filter { !$0.isSavedAsReview }
        var savedCount = 0
        var errors: [String] = []

        for annotation in candidates {
            do {
                _ = try saveAsReview(
                    annotationID: annotation.id,
                    book: book,
                    chapters: chapters,
                    currentURL: currentURL,
                    reviewStore: reviewStore
                )
                savedCount += 1
            } catch {
                errors.append("\(annotationTitle(annotation)): \(error.localizedDescription)")
            }
        }

        return AnnotationReviewBatchResult(savedCount: savedCount, errors: errors)
    }

    private func annotationTitle(_ annotation: PreviewAnnotation) -> String {
        annotation.note.nilIfBlank.map { String($0.prefix(40)) }
            ?? String(annotation.exact.prefix(40))
    }

    private func normalizedChapterPath(_ path: String) -> String {
        ChapterResolver.normalizedDocsRelativeMarkdownPath(
            path.replacingOccurrences(of: "\\", with: "/")
        )
    }

    private func normalizePaths(_ annotation: PreviewAnnotation) -> PreviewAnnotation {
        var copy = annotation
        copy.chapterPath = normalizedChapterPath(annotation.chapterPath)
        return copy
    }

    private func loadDocument(book: BookConfig) throws -> PreviewAnnotationDocument {
        let appSupportURL = Self.appSupportFileURL(bookID: book.id)
        if FileManager.default.fileExists(atPath: appSupportURL.path),
           let cached = try? loadExistingDocument(from: appSupportURL) {
            return cached
        }

        let projectDoc = try? book.withSecurityScopedProjectRoot {
            let projectURL = projectAnnotationsFileURL(book: book)
            guard FileManager.default.fileExists(atPath: projectURL.path) else { return PreviewAnnotationDocument.empty() }
            return try loadExistingDocument(from: projectURL)
        }

        return projectDoc ?? .empty()
    }

    private func loadExistingDocument(from url: URL) throws -> PreviewAnnotationDocument {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder.flexibleDates.decode(PreviewAnnotationDocument.self, from: data)
        if document.version == PreviewAnnotationDocument.currentVersion {
            return document
        }
        return PreviewAnnotationDocument(version: PreviewAnnotationDocument.currentVersion, annotations: document.annotations)
    }

    private func persist(book: BookConfig) throws {
        let document = PreviewAnnotationDocument(version: PreviewAnnotationDocument.currentVersion, annotations: annotations)
        let data = try JSONEncoder.pretty.encode(document)

        let appSupportURL = Self.appSupportFileURL(bookID: book.id)
        try FileManager.default.createDirectory(at: appSupportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: appSupportURL, options: [.atomic])

        do {
            try book.withSecurityScopedProjectRoot {
                let projectURL = projectAnnotationsFileURL(book: book)
                try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: projectURL, options: [.atomic])
            }
        } catch {
            // App Support copy is authoritative; project mirror is best-effort.
        }

        lastError = nil
    }

    private func projectAnnotationsFileURL(book: BookConfig) -> URL {
        URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(fileRelativePath)
    }

    private static func appSupportFileURL(bookID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("BookLoop", isDirectory: true)
            .appendingPathComponent("annotations", isDirectory: true)
            .appendingPathComponent("\(bookID.uuidString).json")
    }
}

enum PreviewAnnotationStoreError: LocalizedError {
    case missingSelection
    case annotationNotFound
    case alreadySavedAsReview

    var errorDescription: String? {
        switch self {
        case .missingSelection:
            return "Select text in the preview first."
        case .annotationNotFound:
            return "Annotation not found."
        case .alreadySavedAsReview:
            return "This note is already saved as a review."
        }
    }
}

struct AnnotationReviewBatchResult {
    var savedCount: Int
    var errors: [String]
}
