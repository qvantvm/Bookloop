import Foundation
import SwiftUI

@MainActor
final class SearchPanelModel: ObservableObject {
    @Published var query = ""
    @Published var scope: SearchScope = .wholeProject
    @Published var isSearching = false
    @Published var plan: SearchPlan?
    @Published var results: [ContentSearchResult] = []
    @Published var usedFallbackPlanning = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let planner = ContentSearchPlanner()

    var canSearch: Bool {
        !isSearching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var matchCount: Int { results.count }
    var fileCount: Int { Set(results.map(\.relativePath)).count }

    var groupedResults: [(path: String, matches: [ContentSearchResult])] {
        let grouped = Dictionary(grouping: results, by: \.relativePath)
        return grouped.keys.sorted().map { path in
            (path: path, matches: grouped[path]?.sorted { $0.lineNumber < $1.lineNumber } ?? [])
        }
    }

    func search(projectStore: BookProjectStore, settingsStore: AppSettingsStore) async {
        guard let project = projectStore.project else {
            errorMessage = "Select a book first."
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Describe what you are looking for."
            return
        }

        isSearching = true
        errorMessage = nil
        infoMessage = nil
        plan = nil
        results = []
        usedFallbackPlanning = false

        do {
            let resolvedPlan: SearchPlan
            if settingsStore.hasAPIKey {
                resolvedPlan = try await planner.plan(
                    naturalLanguageQuery: trimmed,
                    project: project,
                    scope: scope,
                    apiKey: settingsStore.apiKey,
                    model: settingsStore.openAIModel
                )
            } else {
                resolvedPlan = planner.fallbackPlan(query: trimmed, scope: scope)
                usedFallbackPlanning = true
                infoMessage = "Add your OpenAI API key in App Settings for smarter search planning."
            }

            plan = resolvedPlan
            results = try planner.execute(
                plan: resolvedPlan,
                scope: scope,
                project: project,
                searchIndex: projectStore.searchIndex
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }
}

struct SearchPanelView: View {
    @ObservedObject var projectStore: BookProjectStore
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var model: SearchPanelModel
    @ObservedObject var previewModel: BookPreviewModel
    @Binding var workspaceMode: WorkspaceMode
    @Binding var showingAppSettings: Bool

    @State private var planDetailsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    queryCard
                    if let info = model.infoMessage {
                        infoBanner(info)
                    }
                    if let error = model.errorMessage ?? projectStore.lastError {
                        errorBanner(error)
                    }
                    if model.isSearching {
                        searchingCard
                    }
                    if let plan = model.plan, !model.isSearching {
                        planCard(plan)
                        coverageCard
                    }
                    if !model.results.isEmpty {
                        resultsSection
                    } else if model.plan != nil && !model.isSearching {
                        emptyResultsCard
                    }
                }
                .padding()
            }
        }
        .onAppear {
            settingsStore.load()
            projectStore.refresh(book: projectStore.project?.book, currentChapterID: projectStore.project?.currentChapterID)
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let project = projectStore.project {
                        Text(project.book.displayName)
                            .font(.headline)
                        Text(project.projectMap.compactSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No book selected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Model: \(settingsStore.openAIModel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            if projectStore.project == nil {
                Text("Select a book in the sidebar first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !settingsStore.hasAPIKey {
                HStack(spacing: 8) {
                    Text("Literal search only until you add an OpenAI API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open App Settings") { showingAppSettings = true }
                        .font(.caption)
                }
            }
        }
        .padding(10)
    }

    private var queryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe your search")
                .font(.subheadline.weight(.semibold))

            TextField(
                "e.g. mentions of LoRA fine-tuning, or where we explain attention",
                text: $model.query,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)

            Picker("Scope", selection: $model.scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            Button {
                Task {
                    await model.search(projectStore: projectStore, settingsStore: settingsStore)
                }
            } label: {
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Search")
                }
            }
            .disabled(!model.canSearch || projectStore.project == nil)
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Planning search and scanning project files…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func planCard(_ plan: SearchPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color.accentColor)
                Text("Search plan")
                    .font(.subheadline.weight(.semibold))
                if model.usedFallbackPlanning {
                    Text("Literal")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Text(plan.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Planned queries", isExpanded: $planDetailsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(plan.searches.enumerated()), id: \.offset) { index, search in
                        plannedQueryRow(index: index, search: search)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func plannedQueryRow(index: Int, search: SearchQuery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Query \(index + 1): \(search.method == .grep ? "grep" : "search_text")")
                .font(.caption.weight(.semibold))
            if search.method == .grep, let pattern = search.pattern?.nilIfBlank {
                Text("Pattern: `\(pattern)`")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if search.method == .searchText, let text = search.query?.nilIfBlank {
                Text("Text: `\(text)`")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let glob = search.glob?.nilIfBlank {
                Text("Glob: \(glob)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !search.rationale.isEmpty {
                Text(search.rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var coverageCard: some View {
        HStack(spacing: 8) {
            Image(systemName: model.matchCount > 0 ? "checkmark.circle" : "minus.circle")
                .foregroundStyle(model.matchCount > 0 ? .green : .secondary)
            Text(coverageSummary)
                .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var coverageSummary: String {
        if model.matchCount == 0 {
            return "0 matches — topic may be absent or described differently."
        }
        let fileLabel = model.fileCount == 1 ? "file" : "files"
        let matchLabel = model.matchCount == 1 ? "match" : "matches"
        return "\(model.matchCount) \(matchLabel) in \(model.fileCount) \(fileLabel)"
    }

    private var emptyResultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matches")
                .font(.subheadline.weight(.semibold))
            Text("Try broader phrasing, alternate spellings, or a different scope.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Results")
                .font(.subheadline.weight(.semibold))

            ForEach(model.groupedResults, id: \.path) { group in
                resultFileCard(path: group.path, matches: group.matches)
            }
        }
    }

    private func resultFileCard(path: String, matches: [ContentSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.caption.weight(.semibold).monospaced())
                        .textSelection(.enabled)
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDocsChapterPath(path) {
                    Button("Open in Reading") {
                        openInReading(path: path)
                    }
                    .font(.caption)
                } else if let book = projectStore.project?.book {
                    Button("Reveal in Finder") {
                        revealInFinder(relativePath: path, book: book)
                    }
                    .font(.caption)
                }
            }

            ForEach(matches) { match in
                HStack(alignment: .top, spacing: 8) {
                    Text("L\(match.lineNumber)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .trailing)
                    Text(match.snippet)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func isDocsChapterPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.hasPrefix("docs/") && normalized.hasSuffix(".md")
    }

    private func openInReading(path: String) {
        let chapterPath = ChapterResolver.normalizedDocsRelativeMarkdownPath(path)
        previewModel.navigateToChapter(chapterPath)
        workspaceMode = .reading
    }

    private func revealInFinder(relativePath: String, book: BookConfig) {
        let absolute = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .path
        FileHelpers.openInFinder(path: absolute)
    }

    private func infoBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
