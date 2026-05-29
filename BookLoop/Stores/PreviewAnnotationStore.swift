import Foundation

@MainActor
final class PreviewAnnotationStore: ObservableObject {
    @Published private(set) var annotations: [PreviewAnnotation] = []
    @Published var selectedAnnotationID: UUID?
    @Published var isEditorPresented = false
    @Published var draftNote = ""
    @Published var draftQuote: PreviewSelectionQuote?
    @Published var editingAnnotationID: UUID?
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
        loadedBookID = book.id
        do {
            annotations = try loadDocument(book: book).annotations
            lastError = nil
        } catch {
            annotations = []
            lastError = error.localizedDescription
        }
    }

    func annotations(for chapterPath: String) -> [PreviewAnnotation] {
        let normalized = chapterPath.replacingOccurrences(of: "\\", with: "/")
        return annotations
            .filter { $0.chapterPath.replacingOccurrences(of: "\\", with: "/") == normalized }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func annotation(id: UUID) -> PreviewAnnotation? {
        annotations.first { $0.id == id }
    }

    func beginCreate(quote: PreviewSelectionQuote) {
        draftQuote = quote
        draftNote = ""
        editingAnnotationID = nil
        isEditorPresented = true
    }

    func beginEdit(_ annotation: PreviewAnnotation) {
        draftQuote = annotation.quote
        draftNote = annotation.note
        editingAnnotationID = annotation.id
        selectedAnnotationID = annotation.id
        isEditorPresented = true
    }

    func cancelEditor() {
        isEditorPresented = false
        draftQuote = nil
        draftNote = ""
        editingAnnotationID = nil
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
        let normalizedPath = chapterPath.replacingOccurrences(of: "\\", with: "/")
        let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved: PreviewAnnotation
        if let editingAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == editingAnnotationID }) {
            var updated = annotations[index]
            updated.exact = trimmedExact
            updated.prefix = quote.prefix
            updated.suffix = quote.suffix
            updated.note = note
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
        lastError = nil
        return saved
    }

    func delete(id: UUID, book: BookConfig) throws {
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id {
            selectedAnnotationID = nil
        }
        try persist(book: book)
    }

    private func loadDocument(book: BookConfig) throws -> PreviewAnnotationDocument {
        try book.withSecurityScopedProjectRoot {
            let url = annotationsFileURL(book: book)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .empty()
            }
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(PreviewAnnotationDocument.self, from: data)
            if document.version == PreviewAnnotationDocument.currentVersion {
                return document
            }
            return PreviewAnnotationDocument(version: PreviewAnnotationDocument.currentVersion, annotations: document.annotations)
        }
    }

    private func persist(book: BookConfig) throws {
        try book.withSecurityScopedProjectRoot {
            let url = annotationsFileURL(book: book)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let document = PreviewAnnotationDocument(version: PreviewAnnotationDocument.currentVersion, annotations: annotations)
            let data = try JSONEncoder.pretty.encode(document)
            try data.write(to: url, options: [.atomic])
        }
    }

    private func annotationsFileURL(book: BookConfig) -> URL {
        URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(fileRelativePath)
    }
}

enum PreviewAnnotationStoreError: LocalizedError {
    case missingSelection

    var errorDescription: String? {
        switch self {
        case .missingSelection:
            return "Select text in the preview first."
        }
    }
}
