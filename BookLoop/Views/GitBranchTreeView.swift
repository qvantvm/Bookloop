import SwiftUI

struct GitBranchListView: View {
    let snapshot: GitHistorySnapshot
    let selectedBranchName: String?
    let onSelectBranch: (GitRefLabel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text("Branches")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if snapshot.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading branches…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                Spacer(minLength: 0)
            } else if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer(minLength: 0)
            } else if snapshot.branches.isEmpty {
                Text("No branches found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.branches) { branch in
                            branchRow(branch)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private func branchRow(_ branch: GitRefLabel) -> some View {
        let isCurrent = isCurrentBranch(branch)
        let isSelected = selectedBranchName == branch.name || selectedBranchName == branch.displayName

        Button {
            onSelectBranch(branch)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: branch.kind == .remote ? "icloud" : "arrow.branch")
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.displayName)
                        .font(.caption.weight(isCurrent || isSelected ? .semibold : .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if branch.kind == .remote {
                        Text("remote")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isSelected ? Color.accentColor : Color.secondary).opacity(isSelected ? 0.14 : 0.06),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func isCurrentBranch(_ branch: GitRefLabel) -> Bool {
        guard let current = snapshot.currentBranch else { return false }
        if current == "HEAD" { return false }
        return branch.name == current
            || branch.displayName == current
            || branch.fullName == "refs/heads/\(current)"
    }
}

struct GitWorkingChangesView: View {
    let snapshot: GitChangesSnapshot
    var expandsToFillHeight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(Color.accentColor)
                Text("Working Changes")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !snapshot.isLoading, snapshot.errorMessage == nil {
                    Text(summaryLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading changes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if snapshot.isClean {
                Label("No staged or modified files", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let changesContent = VStack(alignment: .leading, spacing: 8) {
                    if !snapshot.staged.isEmpty {
                        changeSection(title: "Staged", systemImage: "tray.and.arrow.down.fill", changes: snapshot.staged)
                    }
                    if !snapshot.unstaged.isEmpty {
                        changeSection(title: "Modified", systemImage: "pencil", changes: snapshot.unstaged)
                    }
                }

                if expandsToFillHeight {
                    ScrollView {
                        changesContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    changesContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expandsToFillHeight ? .infinity : nil, alignment: .topLeading)
    }

    private var summaryLabel: String {
        let stagedCount = snapshot.staged.count
        let unstagedCount = snapshot.unstaged.count
        switch (stagedCount, unstagedCount) {
        case (0, 0): return "Clean"
        case let (s, 0): return "\(s) staged"
        case let (0, u): return "\(u) modified"
        case let (s, u): return "\(s) staged · \(u) modified"
        }
    }

    @ViewBuilder
    private func changeSection(title: String, systemImage: String, changes: [GitFileChange]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(title) (\(changes.count))", systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(changes) { change in
                GitFileChangeRow(change: change)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GitFileChangeRow: View {
    let change: GitFileChange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(change.kind.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(kindColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(change.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if let oldPath = change.oldPath {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                        Text(oldPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var kindColor: Color {
        switch change.kind {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .copied: return .purple
        }
    }
}

struct GitBranchTreeView: View {
    let snapshot: GitHistorySnapshot
    var expandsToFillHeight: Bool = false

    private static let laneWidth: CGFloat = 14
    private static let rowHeight: CGFloat = 58
    private static let branchPalette: [Color] = [
        .blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint, .cyan, .brown
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            historyHeader

            if snapshot.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading commit history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else if snapshot.rows.isEmpty {
                Text("No commits found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                            GitGraphRowView(
                                row: row,
                                isFirst: index == 0,
                                isLast: index == snapshot.rows.count - 1,
                                currentBranch: snapshot.currentBranch,
                                laneWidth: Self.laneWidth,
                                rowHeight: Self.rowHeight,
                                color: color(for: row.commit)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: expandsToFillHeight ? .infinity : 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expandsToFillHeight ? .infinity : nil, alignment: .topLeading)
    }

    @ViewBuilder
    private var historyHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.accentColor)
            Text("Commit History")
                .font(.caption.weight(.semibold))
            Spacer()
            if let branch = snapshot.currentBranch, branch != "HEAD" {
                Label(branch, systemImage: "arrow.branch")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            } else if snapshot.currentBranch == "HEAD" {
                Text("Detached HEAD")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for commit: GitCommitRecord) -> Color {
        let key = commit.refs.first(where: { $0.kind == .branch })?.name
            ?? commit.refs.first?.name
            ?? commit.shortHash
        let hash = abs(key.hashValue)
        return Self.branchPalette[hash % Self.branchPalette.count]
    }
}

private struct GitGraphRowView: View {
    let row: GitGraphRow
    let isFirst: Bool
    let isLast: Bool
    let currentBranch: String?
    let laneWidth: CGFloat
    let rowHeight: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GitGraphLaneView(
                row: row,
                isFirst: isFirst,
                isLast: isLast,
                laneWidth: laneWidth,
                rowHeight: rowHeight,
                color: color
            )
            .frame(width: graphWidth, height: rowHeight)

            commitCard
        }
        .frame(minHeight: rowHeight)
    }

    private var graphWidth: CGFloat {
        max(CGFloat(row.columnCount) * laneWidth + 6, laneWidth + 6)
    }

    private var commitCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.commit.shortHash)
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(color)

                if row.commit.isMerge {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(row.commit.subject)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text(row.commit.author)
                    .lineLimit(1)
                Text("·")
                Text(row.commit.date, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !row.commit.refs.isEmpty {
                GitRefBadgeRow(refs: row.commit.refs, currentBranch: currentBranch, accent: color)
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
    }
}

private struct GitGraphLaneView: View {
    let row: GitGraphRow
    let isFirst: Bool
    let isLast: Bool
    let laneWidth: CGFloat
    let rowHeight: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let lineWidth: CGFloat = 2
            let laneColor = Color.secondary.opacity(0.35)

            func point(for column: Int, y: CGFloat) -> CGPoint {
                CGPoint(x: CGFloat(column) * laneWidth + laneWidth / 2, y: y)
            }

            for column in row.lanesBefore where column != row.column {
                var path = Path()
                path.move(to: point(for: column, y: 0))
                path.addLine(to: point(for: column, y: size.height))
                context.stroke(path, with: .color(laneColor), lineWidth: lineWidth)
            }

            if row.lanesBefore.contains(row.column) && !isFirst {
                var path = Path()
                path.move(to: point(for: row.column, y: 0))
                path.addLine(to: point(for: row.column, y: midY))
                context.stroke(path, with: .color(laneColor), lineWidth: lineWidth)
            }

            for branch in row.branchLines {
                var path = Path()
                let start = point(for: branch.from, y: midY)
                let end = point(for: branch.to, y: midY)
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: lineWidth)
            }

            for column in row.lanesAfter where column != row.column {
                var path = Path()
                path.move(to: point(for: column, y: midY))
                path.addLine(to: point(for: column, y: size.height))
                context.stroke(path, with: .color(laneColor), lineWidth: lineWidth)
            }

            if row.lanesAfter.contains(row.column) || !row.commit.parents.isEmpty {
                var path = Path()
                path.move(to: point(for: row.column, y: midY))
                path.addLine(to: point(for: row.column, y: size.height))
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: lineWidth)
            }

            let dotRect = CGRect(
                x: point(for: row.column, y: midY).x - 4.5,
                y: midY - 4.5,
                width: 9,
                height: 9
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
            context.stroke(Path(ellipseIn: dotRect), with: .color(.primary.opacity(0.15)), lineWidth: 1)
        }
    }
}

private struct GitRefBadgeRow: View {
    let refs: [GitRefLabel]
    let currentBranch: String?
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(refs.prefix(4)) { ref in
                    Text(ref.displayName)
                        .font(.system(size: 10, weight: isCurrent(ref) ? .semibold : .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (isCurrent(ref) ? accent : Color.secondary).opacity(isCurrent(ref) ? 0.18 : 0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(isCurrent(ref) ? accent : .secondary)
                }
                if refs.count > 4 {
                    Text("+\(refs.count - 4)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func isCurrent(_ ref: GitRefLabel) -> Bool {
        guard let currentBranch else { return false }
        return ref.name == currentBranch || ref.fullName == "refs/heads/\(currentBranch)"
    }
}
