import Foundation

struct BookConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var projectRootPath: String
    var projectRootBookmark: Data?
    var bookloopConfigPath: String?
    var llmsTxtPath: String?
    var docsPath: String?
    var reviewsPath: String?
    var reviewItemsPath: String?
    var cumulativeReviewPath: String?
    var figuresSourcePath: String?
    var figuresOutputPath: String?
    var bookloopPath: String?
    var styleGuidePath: String?
    var figuresRegistryPath: String?
    var figureGenerationCommand: String?
    var validationCommand: String?
    var allowShellCommands: Bool
    var allowFigureRegeneration: Bool
    var allowPatchApply: Bool
    var notes: String?

    var allowsPatchGitCommands: Bool {
        allowPatchApply || allowShellCommands
    }

    static func defaults(projectRootPath: String = "") -> BookConfig {
        var book = BookConfig(
            id: UUID(),
            displayName: "Untitled Book",
            projectRootPath: projectRootPath,
            projectRootBookmark: nil,
            bookloopConfigPath: nil,
            llmsTxtPath: nil,
            docsPath: nil,
            reviewsPath: nil,
            reviewItemsPath: nil,
            cumulativeReviewPath: nil,
            figuresSourcePath: nil,
            figuresOutputPath: nil,
            bookloopPath: nil,
            styleGuidePath: nil,
            figuresRegistryPath: nil,
            figureGenerationCommand: nil,
            validationCommand: nil,
            allowShellCommands: false,
            allowFigureRegeneration: false,
            allowPatchApply: true,
            notes: nil
        )
        book.inferExistingPaths()
        return book
    }

    mutating func inferExistingPaths() {
        guard !projectRootPath.isEmpty else { return }
        let root = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        let fm = FileManager.default

        func existing(_ relativePath: String, directory: Bool? = nil) -> String? {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            if let directory, isDirectory.boolValue != directory { return nil }
            return url.path
        }

        bookloopConfigPath = existing("bookloop.yml", directory: false)
            ?? existing("bookloop.yaml", directory: false)
            ?? existing("nav.yml", directory: false)
            ?? existing("nav.yaml", directory: false)
            ?? existing("mkdocs.yml", directory: false)
            ?? bookloopConfigPath
        llmsTxtPath = existing("llms.txt", directory: false)
            ?? existing("static/llms.txt", directory: false)
            ?? llmsTxtPath
        docsPath = existing("docs", directory: true) ?? docsPath
        reviewsPath = existing("reviews", directory: true) ?? reviewsPath
        reviewItemsPath = existing("reviews/review_items", directory: true) ?? reviewItemsPath
        cumulativeReviewPath = existing("reviews/cumulative_review.md", directory: false) ?? cumulativeReviewPath
        figuresSourcePath = existing("figures", directory: true) ?? figuresSourcePath
        figuresOutputPath = existing("docs/assets/figures", directory: true) ?? figuresOutputPath
        bookloopPath = existing("bookloop", directory: true) ?? bookloopPath
        styleGuidePath = existing("bookloop/style_guide.md", directory: false) ?? styleGuidePath
        figuresRegistryPath = existing("bookloop/figures.json", directory: false) ?? figuresRegistryPath
    }

    mutating func refreshProjectRootBookmark() {
        guard !projectRootPath.isEmpty else {
            projectRootBookmark = nil
            return
        }
        let url = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        projectRootBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func withSecurityScopedProjectRoot<T>(_ work: () throws -> T) rethrows -> T {
        var didStartAccessing = false
        var scopedURL: URL?
        if let projectRootBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: projectRootBookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                scopedURL = url
                didStartAccessing = url.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if didStartAccessing {
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }


    mutating func fillSuggestedPaths() {
        guard !projectRootPath.isEmpty else { return }
        bookloopConfigPath = bookloopConfigPath ?? preferredBookloopConfigPath()
        llmsTxtPath = llmsTxtPath ?? BookLLMsContext.resolvePath(for: self)
        docsPath = docsPath ?? suggestedPath("docs")
        reviewsPath = reviewsPath ?? suggestedPath("reviews")
        reviewItemsPath = reviewItemsPath ?? suggestedPath("reviews/review_items")
        cumulativeReviewPath = cumulativeReviewPath ?? suggestedPath("reviews/cumulative_review.md")
        figuresSourcePath = figuresSourcePath ?? suggestedPath("figures")
        figuresOutputPath = figuresOutputPath ?? suggestedPath("docs/assets/figures")
        bookloopPath = bookloopPath ?? suggestedPath("bookloop")
        styleGuidePath = styleGuidePath ?? suggestedPath("bookloop/style_guide.md")
        figuresRegistryPath = figuresRegistryPath ?? suggestedPath("bookloop/figures.json")
    }

    func suggestedPath(_ relativePath: String) -> String {
        URL(fileURLWithPath: projectRootPath, isDirectory: true).appendingPathComponent(relativePath).path
    }

    private func preferredBookloopConfigPath() -> String {
        for name in BookloopYamlConfig.allFileNames {
            let path = suggestedPath(name)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return suggestedPath("bookloop.yml")
    }

    var taskDirectoryPath: String {
        if let bookloopPath {
            return URL(fileURLWithPath: bookloopPath, isDirectory: true).appendingPathComponent("tasks", isDirectory: true).path
        }
        return suggestedPath("bookloop/tasks")
    }

    var patchDirectoryPath: String {
        if let bookloopPath {
            return URL(fileURLWithPath: bookloopPath, isDirectory: true).appendingPathComponent("patches", isDirectory: true).path
        }
        return suggestedPath("bookloop/patches")
    }
}

extension BookConfig {
    enum CodingKeys: String, CodingKey {
        case id, displayName, projectRootPath, projectRootBookmark
        case bookloopConfigPath, navConfigPath
        case llmsTxtPath
        case docsPath, reviewsPath, reviewItemsPath, cumulativeReviewPath
        case figuresSourcePath, figuresOutputPath, bookloopPath, styleGuidePath
        case figuresRegistryPath, figureGenerationCommand, validationCommand
        case allowShellCommands, allowFigureRegeneration, allowPatchApply, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        projectRootPath = try container.decode(String.self, forKey: .projectRootPath)
        projectRootBookmark = try container.decodeIfPresent(Data.self, forKey: .projectRootBookmark)
        bookloopConfigPath = try container.decodeIfPresent(String.self, forKey: .bookloopConfigPath)
            ?? container.decodeIfPresent(String.self, forKey: .navConfigPath)
        llmsTxtPath = try container.decodeIfPresent(String.self, forKey: .llmsTxtPath)
        docsPath = try container.decodeIfPresent(String.self, forKey: .docsPath)
        reviewsPath = try container.decodeIfPresent(String.self, forKey: .reviewsPath)
        reviewItemsPath = try container.decodeIfPresent(String.self, forKey: .reviewItemsPath)
        cumulativeReviewPath = try container.decodeIfPresent(String.self, forKey: .cumulativeReviewPath)
        figuresSourcePath = try container.decodeIfPresent(String.self, forKey: .figuresSourcePath)
        figuresOutputPath = try container.decodeIfPresent(String.self, forKey: .figuresOutputPath)
        bookloopPath = try container.decodeIfPresent(String.self, forKey: .bookloopPath)
        styleGuidePath = try container.decodeIfPresent(String.self, forKey: .styleGuidePath)
        figuresRegistryPath = try container.decodeIfPresent(String.self, forKey: .figuresRegistryPath)
        figureGenerationCommand = try container.decodeIfPresent(String.self, forKey: .figureGenerationCommand)
        validationCommand = try container.decodeIfPresent(String.self, forKey: .validationCommand)
        allowShellCommands = try container.decode(Bool.self, forKey: .allowShellCommands)
        allowFigureRegeneration = try container.decode(Bool.self, forKey: .allowFigureRegeneration)
        allowPatchApply = try container.decode(Bool.self, forKey: .allowPatchApply)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(projectRootPath, forKey: .projectRootPath)
        try container.encodeIfPresent(projectRootBookmark, forKey: .projectRootBookmark)
        try container.encodeIfPresent(bookloopConfigPath, forKey: .bookloopConfigPath)
        try container.encodeIfPresent(llmsTxtPath, forKey: .llmsTxtPath)
        try container.encodeIfPresent(docsPath, forKey: .docsPath)
        try container.encodeIfPresent(reviewsPath, forKey: .reviewsPath)
        try container.encodeIfPresent(reviewItemsPath, forKey: .reviewItemsPath)
        try container.encodeIfPresent(cumulativeReviewPath, forKey: .cumulativeReviewPath)
        try container.encodeIfPresent(figuresSourcePath, forKey: .figuresSourcePath)
        try container.encodeIfPresent(figuresOutputPath, forKey: .figuresOutputPath)
        try container.encodeIfPresent(bookloopPath, forKey: .bookloopPath)
        try container.encodeIfPresent(styleGuidePath, forKey: .styleGuidePath)
        try container.encodeIfPresent(figuresRegistryPath, forKey: .figuresRegistryPath)
        try container.encodeIfPresent(figureGenerationCommand, forKey: .figureGenerationCommand)
        try container.encodeIfPresent(validationCommand, forKey: .validationCommand)
        try container.encode(allowShellCommands, forKey: .allowShellCommands)
        try container.encode(allowFigureRegeneration, forKey: .allowFigureRegeneration)
        try container.encode(allowPatchApply, forKey: .allowPatchApply)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

struct Chapter: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var markdownPath: String
    var relativePath: String
    var urlSlug: String?
    var order: Int?
}

enum FeedbackType: String, Codable, CaseIterable, Identifiable {
    case question
    case confusion
    case missingExample = "missing_example"
    case missingReference = "missing_reference"
    case outdatedClaim = "outdated_claim"
    case wrongOrUnclear = "wrong_or_unclear"
    case figureNeeded = "figure_needed"
    case exerciseNeeded = "exercise_needed"
    case structureIssue = "structure_issue"
    case styleIssue = "style_issue"
    case implementationNote = "implementation_note"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .question: return "Question"
        case .confusion: return "Confusion"
        case .missingExample: return "Missing Example"
        case .missingReference: return "Missing Reference"
        case .outdatedClaim: return "Outdated Claim"
        case .wrongOrUnclear: return "Wrong or Unclear"
        case .figureNeeded: return "Figure Needed"
        case .exerciseNeeded: return "Exercise Needed"
        case .structureIssue: return "Structure Issue"
        case .styleIssue: return "Style Issue"
        case .implementationNote: return "Implementation Note"
        case .other: return "Other"
        }
    }
}

enum FeedbackSeverity: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case critical

    var id: String { rawValue }

    var rank: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }
}

struct ReviewRequest: Codable {
    let chapter: String
    let type: String
    let severity: String
    let title: String
    let body: String
    let section: String?
    let suggested_fix: String?
}

struct ReviewResponse: Codable {
    let ok: Bool
    let id: String
    let file: String
}

enum LocalAPIStatus: Equatable {
    case unknown
    case checking
    case online
    case offline(String?)
    case notConfigured

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking"
        case .online: return "Online"
        case .offline: return "Offline"
        case .notConfigured: return "Not Configured"
        }
    }
}

struct ReviewItem: Identifiable, Codable, Equatable {
    var id: String
    var filePath: String
    var chapter: String?
    var type: String?
    var severity: String?
    var section: String?
    var title: String
    var body: String?
    var suggestedFix: String?
    var sourceFile: String?
    var status: ReviewStatus
    var createdAt: Date?
}

struct ReviewIndexDocument: Equatable {
    var lastRebuilt: Date?
    var items: [ReviewIndexEntry]
    var rawJSON: String?

    var openCount: Int {
        items.filter { $0.status.lowercased() == "open" }.count
    }

    var resolvedCount: Int {
        items.filter { $0.status.lowercased() == "resolved" }.count
    }
}

struct ReviewIndexEntry: Identifiable, Equatable {
    var id: String
    var chapterID: String?
    var title: String
    var type: String?
    var severity: String?
    var status: String
    var createdAt: Date?
    var file: String?
}

enum ReviewStatus: String, Codable, CaseIterable {
    case open
    case resolved
    case fixed
    case rejected
    case needsDiscussion = "needs_discussion"
    case unknown

    var isOpenForWorkflow: Bool {
        self == .open
    }
}

struct RevisionTask: Identifiable, Codable {
    var id: UUID
    var createdAt: Date
    var title: String
    var bookName: String
    var bookRootPath: String
    var chapterID: String?
    var reviewItemIDs: [String]
    var selectedText: String?
    var mode: RevisionTaskMode
    var constraints: [String]
    var expectedOutputs: [String]
}

enum RevisionTaskMode: String, Codable, CaseIterable, Identifiable {
    case proposePatchOnly = "propose_patch_only"
    case planOnly = "plan_only"
    case proposeFigure = "propose_figure"
    case fixReviews = "fix_reviews"
    case validateBook = "validate_book"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proposePatchOnly: return "Propose Patch Only"
        case .planOnly: return "Plan Only"
        case .proposeFigure: return "Propose Figure"
        case .fixReviews: return "Fix Reviews"
        case .validateBook: return "Validate Book"
        }
    }
}

struct FigureItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String?
    var chapterID: String?
    var section: String?
    var sourcePath: String?
    var outputPath: String
    var referencedFrom: [String]
    var type: FigureType
    var status: FigureStatus
    var caption: String?
    var generationCommand: String?
    var lastGeneratedAt: Date?
    var isStale: Bool
}

enum FigureType: String, Codable, CaseIterable {
    case python
    case tikz
    case mermaid
    case graphviz
    case svg
    case png
    case jpg
    case imageModel = "image_model"
    case unknown
}

enum FigureStatus: String, Codable, CaseIterable {
    case ok
    case missingOutput = "missing_output"
    case stale
    case unreferenced
    case referencedButUnregistered = "referenced_but_unregistered"
    case unknown
}

struct PatchProposal: Identifiable, Codable, Equatable {
    var id: UUID
    var filePath: String
    var title: String
    var summary: String?
    var createdAt: Date?
    var changedFiles: [String]
    var rawPatch: String

    var rootStem: String { PatchFileHelpers.rootPatchStem(from: title) }
    var isReviewedCopy: Bool { PatchFileHelpers.isReviewedCopy(filename: title) }
    var displayTitle: String { rootStem }
    var kindLabel: String { isReviewedCopy ? "Reviewed copy" : "Agent proposal" }
}

enum PatchWorkflowPhase: Equatable {
    case reviewing
    case appliedToDisk
    case committed
    case alreadyApplied

    var displayName: String {
        switch self {
        case .reviewing: return "Reviewing"
        case .appliedToDisk: return "Applied to book"
        case .committed: return "Committed"
        case .alreadyApplied: return "Already applied"
        }
    }
}

struct PatchActivityEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var timestamp: Date
    var message: String
}

struct PendingPatchCommitContext: Equatable {
    var changedFiles: [String]
    var evidenceFiles: [String]
    var rootStem: String

    var allCommitPaths: [String] {
        var seen = Set<String>()
        return (changedFiles + evidenceFiles).filter { seen.insert($0).inserted }
    }
}

struct DiffFile: Identifiable, Equatable {
    var id: String
    var oldPath: String
    var newPath: String
    var hunks: [DiffHunk]
}

struct DiffHunk: Identifiable, Equatable {
    var id: UUID
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [DiffLine]
}

enum DiffLineKind: Equatable {
    case context
    case addition
    case deletion
    case header
}

struct DiffLine: Identifiable, Equatable {
    var id: UUID
    var kind: DiffLineKind
    var content: String
}

enum PatchBlockDecision: String, Codable, CaseIterable, Identifiable {
    case pending
    case accepted
    case rejected

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        }
    }
}

struct RenderedPatchBlock: Identifiable, Equatable {
    var id: String
    var fileID: String
    var oldPath: String
    var newPath: String
    var title: String
    var hunkHeader: String
    var oldStart: Int
    var newStart: Int
    var beforeMarkdown: String
    var afterMarkdown: String
    var beforeHTML: String
    var afterHTML: String
    var rawHunkLines: [String]
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case agent = "Agent"
    case reviews = "Reviews"
    case figures = "Figures"
    case tasks = "Tasks"
    case patches = "Patches"
    case settings = "Settings"

    var id: String { rawValue }
}
