import Combine
import Foundation

private struct PersistedLibrary: Codable {
    var books: [BookConfig]
    var selectedBookID: UUID?
}

@MainActor
final class BookLibraryStore: ObservableObject {
    @Published var books: [BookConfig] = [] {
        didSet { saveIfReady() }
    }
    @Published var selectedBookID: UUID? {
        didSet { saveIfReady() }
    }

    private var isLoading = false

    var selectedBook: BookConfig? {
        guard let selectedBookID else { return nil }
        return books.first { $0.id == selectedBookID }
    }

    init() {
        load()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try Self.libraryFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let persisted = try JSONDecoder().decode(PersistedLibrary.self, from: data)
            books = persisted.books
            selectedBookID = persisted.selectedBookID ?? persisted.books.first?.id
        } catch {
            books = []
            selectedBookID = nil
        }
    }

    func save() {
        do {
            let url = try Self.libraryFileURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder.pretty.encode(PersistedLibrary(books: books, selectedBookID: selectedBookID))
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("BookLoop could not save library: \(error.localizedDescription)")
        }
    }

    func addBook(_ book: BookConfig) {
        books.append(book)
        selectedBookID = book.id
    }

    func updateBook(_ book: BookConfig) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
    }

    func deleteBook(_ book: BookConfig) {
        books.removeAll { $0.id == book.id }
        if selectedBookID == book.id {
            selectedBookID = books.first?.id
        }
    }

    private func saveIfReady() {
        guard !isLoading else { return }
        save()
    }

    private static func libraryFileURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BookLoop", isDirectory: true).appendingPathComponent("books.json")
    }
}

@MainActor
final class ProjectContentStore: ObservableObject {
    @Published var chapters: [Chapter] = []
    @Published var errorMessage: String?

    func refresh(book: BookConfig?) {
        guard let book else {
            chapters = []
            errorMessage = nil
            return
        }
        do {
            chapters = try MkDocsProjectScanner().discoverChapters(book: book)
            errorMessage = nil
        } catch {
            chapters = []
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class ReviewStore: ObservableObject {
    enum SortMode: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case severity = "Severity"

        var id: String { rawValue }
    }

    @Published var items: [ReviewItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var chapterFilter = "All"
    @Published var severityFilter = "All"
    @Published var typeFilter = "All"
    @Published var sortMode: SortMode = .newest
    @Published var cumulativeReview: String?
    @Published var reviewIndex: String?
    @Published var errorMessage: String?

    var filteredItems: [ReviewItem] {
        items
            .filter { item in
                (chapterFilter == "All" || item.chapter == chapterFilter)
                    && (severityFilter == "All" || item.severity == severityFilter)
                    && (typeFilter == "All" || item.type == typeFilter)
                    && matchesSearch(item)
            }
            .sorted(by: sort)
    }

    var chapters: [String] {
        Array(Set(items.compactMap(\.chapter))).sorted()
    }

    var severities: [String] {
        Array(Set(items.compactMap(\.severity))).sorted()
    }

    var types: [String] {
        Array(Set(items.compactMap(\.type))).sorted()
    }

    var openCount: Int {
        items.filter { $0.status == .open }.count
    }

    var criticalCount: Int {
        items.filter { $0.severity == FeedbackSeverity.critical.rawValue && $0.status == .open }.count
    }

    func refresh(book: BookConfig?) {
        selectedIDs.removeAll()
        guard let book else {
            items = []
            cumulativeReview = nil
            reviewIndex = nil
            errorMessage = nil
            return
        }
        do {
            let parser = ReviewItemParser()
            items = try parser.parseReviewItems(book: book)
            cumulativeReview = parser.readOptional(path: book.cumulativeReviewPath)
            reviewIndex = parser.readOptional(path: URL(fileURLWithPath: book.reviewsPath ?? book.suggestedPath("reviews"), isDirectory: true).appendingPathComponent("review_index.json").path)
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private func matchesSearch(_ item: ReviewItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = [item.id, item.title, item.body, item.suggestedFix, item.chapter, item.section]
            .compactMap { $0 }
            .joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func sort(_ lhs: ReviewItem, _ rhs: ReviewItem) -> Bool {
        switch sortMode {
        case .newest:
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        case .oldest:
            return (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture)
        case .severity:
            let left = FeedbackSeverity(rawValue: lhs.severity ?? "")?.rank ?? 99
            let right = FeedbackSeverity(rawValue: rhs.severity ?? "")?.rank ?? 99
            return left < right
        }
    }
}

@MainActor
final class FigureStore: ObservableObject {
    @Published var figures: [FigureItem] = []
    @Published var errorMessage: String?

    var okCount: Int { figures.filter { $0.status == .ok }.count }
    var staleCount: Int { figures.filter { $0.status == .stale || $0.isStale }.count }
    var missingCount: Int { figures.filter { $0.status == .missingOutput || $0.status == .referencedButUnregistered }.count }

    func refresh(book: BookConfig?) {
        guard let book else {
            figures = []
            errorMessage = nil
            return
        }
        do {
            figures = try FigureScanner().scan(book: book)
            errorMessage = nil
        } catch {
            figures = []
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published var taskFiles: [URL] = []
    @Published var lastGeneratedText: String?
    @Published var lastGeneratedPath: String?
    @Published var message: String?

    func refresh(book: BookConfig?) {
        guard let book else {
            taskFiles = []
            return
        }
        let directory = URL(fileURLWithPath: book.taskDirectoryPath, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            taskFiles = []
            return
        }
        taskFiles = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
    }

    func generate(book: BookConfig, mode: RevisionTaskMode, chapterID: String?, reviewItems: [ReviewItem], selectedText: String?) {
        do {
            let result = try TaskGenerator().generateTask(book: book, mode: mode, chapterID: chapterID, reviewItems: reviewItems, selectedText: selectedText)
            lastGeneratedText = result.text
            lastGeneratedPath = result.url.path
            message = "Generated \(result.url.lastPathComponent)"
            refresh(book: book)
        } catch {
            message = error.localizedDescription
        }
    }
}

@MainActor
final class PatchStore: ObservableObject {
    @Published var proposals: [PatchProposal] = []
    @Published var selectedProposalID: UUID?
    @Published var message: String?

    var selectedProposal: PatchProposal? {
        guard let selectedProposalID else { return proposals.first }
        return proposals.first { $0.id == selectedProposalID }
    }

    func refresh(book: BookConfig?) {
        guard let book else {
            proposals = []
            selectedProposalID = nil
            return
        }
        proposals = PatchParser().scanPatchDirectory(path: book.patchDirectoryPath)
        if selectedProposalID == nil || !proposals.contains(where: { $0.id == selectedProposalID }) {
            selectedProposalID = proposals.first?.id
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var flexibleDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
