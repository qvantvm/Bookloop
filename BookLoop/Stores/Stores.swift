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
            books = persisted.books.map { $0.clearingLegacyMkdocsValidationCommand() }
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
    @Published var chapterNav: [ChapterNavItem] = []
    @Published var navigationHint: String?
    @Published var usedLegacyMkDocsNav = false
    @Published var navigationResult: BookNavigationScanResult?
    @Published var errorMessage: String?

    func refresh(book: BookConfig?) {
        guard let book else {
            chapters = []
            chapterNav = []
            navigationHint = nil
            usedLegacyMkDocsNav = false
            navigationResult = nil
            errorMessage = nil
            return
        }
        do {
            let result = try NavConfigLoader.loadNavigation(for: book)
            chapters = result.chapters
            chapterNav = result.navItems
            navigationResult = result
            navigationHint = BookloopYamlConfig.migrationHint(for: BookloopYamlConfig.resolveConfigPath(for: book))
            usedLegacyMkDocsNav = result.usedLegacyMkDocsNav
            errorMessage = nil
        } catch {
            chapters = []
            chapterNav = []
            navigationHint = nil
            usedLegacyMkDocsNav = false
            navigationResult = nil
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
    @Published var statusFilter = "Open"
    @Published var sortMode: SortMode = .newest
    @Published var cumulativeReview: String?
    @Published var reviewIndexDocument: ReviewIndexDocument?
    @Published var artifactsHealth: ReviewArtifactsHealth = .healthy
    @Published var indexMissingEntryCount: Int = 0
    @Published var isRepairingArtifacts = false
    @Published var lastArtifactsRepairMessage: String?
    @Published var errorMessage: String?
    @Published var showsSubmitReviewForm = false

    private var maintenanceBook: BookConfig?
    private var maintenanceTimer: Timer?
    private var deferredRepairTask: Task<Void, Never>?

    var filteredItems: [ReviewItem] {
        items
            .filter { item in
                matchesStatusFilter(item)
                    && (chapterFilter == "All" || item.chapter == chapterFilter)
                    && (severityFilter == "All" || item.severity == severityFilter)
                    && (typeFilter == "All" || item.type == typeFilter)
                    && matchesSearch(item)
            }
            .sorted(by: sort)
    }

    var openCount: Int {
        items.filter { $0.status.isOpenForWorkflow }.count
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

    var criticalCount: Int {
        items.filter { $0.severity == FeedbackSeverity.critical.rawValue && $0.status.isOpenForWorkflow }.count
    }

    func refresh(book: BookConfig?) {
        selectedIDs.removeAll()
        guard let book else {
            items = []
            cumulativeReview = nil
            reviewIndexDocument = nil
            artifactsHealth = .healthy
            indexMissingEntryCount = 0
            lastArtifactsRepairMessage = nil
            stopPeriodicMaintenance()
            errorMessage = nil
            return
        }
        do {
            let parser = ReviewItemParser()
            items = try parser.parseAllReviewItems(book: book)
            cumulativeReview = parser.readOptional(path: book.cumulativeReviewPath)
        } catch {
            items = []
            cumulativeReview = nil
            reviewIndexDocument = nil
            errorMessage = error.localizedDescription
            return
        }

        do {
            reviewIndexDocument = try ReviewIndexParser().parse(book: book)
            errorMessage = nil
        } catch {
            reviewIndexDocument = nil
            errorMessage = error.localizedDescription
        }

        updateArtifactsHealth(book: book)
        scheduleDeferredRepairIfNeeded(book: book)
        startPeriodicMaintenance(for: book)
    }

    func rebuildArtifacts(book: BookConfig) async {
        await repairArtifactsIfNeeded(book: book, force: true)
    }

    private func updateArtifactsHealth(book: BookConfig) {
        artifactsHealth = ReviewArtifactsMaintainer.assessHealth(
            book: book,
            indexDocument: reviewIndexDocument,
            cumulativeReview: cumulativeReview
        )
        indexMissingEntryCount = artifactsHealth.missingIndexEntries
    }

    private func scheduleDeferredRepairIfNeeded(book: BookConfig) {
        deferredRepairTask?.cancel()
        guard artifactsHealth.needsRepair else { return }
        deferredRepairTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await repairArtifactsIfNeeded(book: book, force: false)
        }
    }

    private func repairArtifactsIfNeeded(book: BookConfig, force: Bool) async {
        guard !isRepairingArtifacts else { return }
        if !force {
            let health = ReviewArtifactsMaintainer.assessHealth(
                book: book,
                indexDocument: reviewIndexDocument,
                cumulativeReview: cumulativeReview
            )
            guard health.needsRepair else { return }
        }

        isRepairingArtifacts = true
        defer { isRepairingArtifacts = false }
        do {
            let repaired = try await Task(priority: .utility) {
                if force {
                    try ReviewArtifactsMaintainer.repairAll(book: book)
                    return true
                }
                return try ReviewArtifactsMaintainer.repairIfNeeded(book: book)
            }.value
            if repaired {
                lastArtifactsRepairMessage = "Review index and summaries were rebuilt."
            }
            refresh(book: book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPeriodicMaintenance(for book: BookConfig?) {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        maintenanceBook = book
        guard book != nil else { return }

        maintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: ReviewArtifactsMaintainer.maintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self, let book = self.maintenanceBook else { return }
            Task { @MainActor in
                await self.repairArtifactsIfNeeded(book: book, force: false)
            }
        }
    }

    private func stopPeriodicMaintenance() {
        deferredRepairTask?.cancel()
        deferredRepairTask = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        maintenanceBook = nil
    }

    deinit {
        maintenanceTimer?.invalidate()
    }

    func reopenReview(id: String, book: BookConfig) async {
        do {
            try await Task(priority: .userInitiated) {
                try ReviewItemResolver.reopenReview(id: id, book: book)
            }.value
            lastArtifactsRepairMessage = "Review reopened."
            refresh(book: book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matchesStatusFilter(_ item: ReviewItem) -> Bool {
        switch statusFilter {
        case "Resolved":
            return item.status == .resolved
        case "All":
            return true
        default:
            return item.status.isOpenForWorkflow
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
    @Published var lastGeneratedURL: URL?
    @Published var message: String?
    @Published var pendingAgentRun: PendingAgentTaskRun?

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
            lastGeneratedURL = result.url
            message = "Generated \(result.url.lastPathComponent) — running in Agent"
            pendingAgentRun = PendingAgentTaskRun(url: result.url, text: result.text, mode: mode)
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

    var pendingAttentionCount: Int {
        proposals.count
    }

    func refresh(book: BookConfig?) {
        guard let book else {
            proposals = []
            selectedProposalID = nil
            return
        }
        let previousSelection = selectedProposalID
        proposals = PatchParser().scanPatchDirectory(path: book.patchDirectoryPath)
        if proposals.isEmpty {
            selectedProposalID = nil
        } else if selectedProposalID == nil || !proposals.contains(where: { $0.id == selectedProposalID }) {
            selectedProposalID = proposals.first?.id
        }
        if previousSelection != nil, selectedProposalID == nil, !proposals.isEmpty {
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
