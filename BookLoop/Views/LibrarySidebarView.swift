import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var taskStore: TaskStore

    @Binding var isSidebarVisible: Bool
    let previewStatus: LocalAPIStatus
    let chapterItems: [ChapterNavItem]
    let currentChapterPath: String?
    let addBook: () -> Void
    let editBook: () -> Void
    let deleteBook: () -> Void
    let onChapterSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $library.selectedBookID) {
                Section {
                    ForEach(library.books) { book in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.displayName)
                                .fontWeight(.medium)
                            Text(book.projectRootPath.isEmpty ? "No project root" : book.projectRootPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(book.id)
                    }
                } header: {
                    HStack {
                        Text("Books")
                        Spacer()
                        Button {
                            withAnimation { isSidebarVisible = false }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Hide panel")
                    }
                }

                if library.selectedBook != nil {
                    Section("Status") {
                        CompactStatusRow(
                            previewStatus: previewStatus,
                            openReviewCount: reviewStore.openCount
                        )
                    }

                    Section("Chapters") {
                        if chapterItems.isEmpty {
                            Text("Loading chapter list…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(chapterItems) { item in
                                ChapterNavRow(
                                    item: item,
                                    currentChapterPath: currentChapterPath,
                                    level: 0,
                                    onSelect: onChapterSelect
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Button(action: addBook) {
                    Label("Add", systemImage: "plus")
                }
                Button(action: editBook) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .disabled(library.selectedBook == nil)
                Button(role: .destructive, action: deleteBook) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(library.selectedBook == nil)
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
    }
}

private struct CompactStatusRow: View {
    let previewStatus: LocalAPIStatus
    let openReviewCount: Int

    var body: some View {
        HStack(spacing: 8) {
            statusDot(title: "Preview", status: previewStatus)
            Spacer()
            Text("\(openReviewCount) open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func statusDot(title: String, status: LocalAPIStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color(for: status))
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .help("\(title): \(status.label)")
    }

    private func color(for status: LocalAPIStatus) -> Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .checking: return .orange
        case .notConfigured: return .secondary
        case .unknown: return .gray
        }
    }
}

private struct ChapterNavRow: View {
    let item: ChapterNavItem
    let currentChapterPath: String?
    let level: Int
    let onSelect: (String) -> Void

    @State private var isExpanded = true

    private var isSelected: Bool {
        guard item.isNavigable, let currentChapterPath else { return false }
        return item.href == currentChapterPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if !item.children.isEmpty {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
                rowLabel
            }
            .padding(.leading, CGFloat(level * 12))

            if isExpanded {
                ForEach(item.children) { child in
                    ChapterNavRow(item: child, currentChapterPath: currentChapterPath, level: level + 1, onSelect: onSelect)
                }
            }
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        if item.isNavigable {
            Button {
                onSelect(item.href)
            } label: {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .fontWeight(isSelected ? .semibold : .regular)
        } else {
            Button { isExpanded.toggle() } label: {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
