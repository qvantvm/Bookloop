import SwiftUI

struct GitWorkspaceView: View {
    @EnvironmentObject private var library: BookLibraryStore
    let book: BookConfig

    private var activeBook: BookConfig {
        library.selectedBook ?? book
    }

    @State private var gitHistory = GitHistorySnapshot.loading
    @State private var gitChanges = GitChangesSnapshot.loading
    @State private var selectedBranchName: String?
    @State private var commitMessage = ""
    @State private var statusMessage: String?
    @State private var isRunningGitCommand = false
    @State private var confirmingCheckout = false
    @State private var confirmingCommit = false
    @State private var pendingCheckoutBranch: GitRefLabel?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                GitBranchListView(
                    snapshot: gitHistory,
                    selectedBranchName: selectedBranchName ?? gitHistory.currentBranch,
                    onSelectBranch: { branch in
                        selectedBranchName = branch.name
                        if !isCurrentBranch(branch) {
                            pendingCheckoutBranch = branch
                            confirmingCheckout = true
                        }
                    }
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                panelChrome(title: "Commit History", systemImage: "clock.arrow.circlepath") {
                    GitBranchTreeView(snapshot: gitHistory, expandsToFillHeight: true)
                        .padding(12)
                }
                .frame(minWidth: 360)

                panelChrome(title: "Working Tree", systemImage: "doc.badge.clock") {
                    GitWorkingChangesView(snapshot: gitChanges, expandsToFillHeight: true)
                        .padding(12)
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
            }

            Divider()

            gitControlBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: activeBook.projectRootPath) {
            await refreshGitState()
        }
        .alert("Switch branch?", isPresented: $confirmingCheckout) {
            Button("Cancel", role: .cancel) {
                pendingCheckoutBranch = nil
                selectedBranchName = gitHistory.currentBranch
            }
            Button("Checkout", role: .destructive) {
                if let branch = pendingCheckoutBranch {
                    Task { await checkoutBranch(branch) }
                }
                pendingCheckoutBranch = nil
            }
        } message: {
            if let branch = pendingCheckoutBranch {
                Text("BookLoop will run git checkout for “\(branch.displayName)” in this book’s repository.")
            }
        }
        .alert("Commit changes to git?", isPresented: $confirmingCommit) {
            Button("Cancel", role: .cancel) {}
            Button("Commit", role: .destructive) {
                Task { await commitChanges() }
            }
        } message: {
            Text("BookLoop will stage the listed paths (or all tracked changes if none are listed) and create a commit with your message.")
        }
    }

    @ViewBuilder
    private func panelChrome<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var gitControlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await refreshGitState() }
                } label: {
                    Label(isRunningGitCommand ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRunningGitCommand)

                Button {
                    Task { await stageAllChanges() }
                } label: {
                    Label("Stage All", systemImage: "tray.and.arrow.down")
                }
                .disabled(isRunningGitCommand || !activeBook.allowsPatchGitCommands || gitChanges.isClean)

                Spacer()

                if let branch = gitHistory.currentBranch {
                    Label(branch == "HEAD" ? "Detached HEAD" : branch, systemImage: "arrow.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)

                Button(isRunningGitCommand ? "Committing…" : "Commit") {
                    confirmingCommit = true
                }
                .disabled(isRunningGitCommand || !canCommit)

                if !activeBook.allowsPatchGitCommands {
                    Button("Copy Commit Command") {
                        copyCommitCommand()
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else if !activeBook.allowsPatchGitCommands {
                Text("Enable Allow patch apply or Allow shell commands in book Settings to run git commands.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var canCommit: Bool {
        activeBook.allowsPatchGitCommands
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!gitChanges.staged.isEmpty || !gitChanges.unstaged.isEmpty)
    }

    private var allChangedPaths: [String] {
        var seen = Set<String>()
        return (gitChanges.staged + gitChanges.unstaged)
            .map(\.path)
            .filter { seen.insert($0).inserted }
    }

    @MainActor
    private func refreshGitState() async {
        async let history = PatchApplier().gitHistory(book: activeBook)
        async let changes = PatchApplier().gitChanges(book: activeBook)
        gitHistory = await history
        gitChanges = await changes
        if selectedBranchName == nil {
            selectedBranchName = gitHistory.currentBranch
        }
    }

    private func isCurrentBranch(_ branch: GitRefLabel) -> Bool {
        guard let current = gitHistory.currentBranch, current != "HEAD" else { return false }
        return branch.name == current || branch.displayName == current
    }

    @MainActor
    private func checkoutBranch(_ branch: GitRefLabel) async {
        guard activeBook.allowsPatchGitCommands else {
            statusMessage = "Enable Allow patch apply or Allow shell commands in book Settings."
            return
        }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            let result = try await PatchApplier().gitCheckout(ref: branch.name, book: activeBook)
            if result.exitCode == 0 {
                statusMessage = "Checked out \(branch.displayName)."
                selectedBranchName = branch.name
                await refreshGitState()
            } else {
                statusMessage = result.combinedOutput.nilIfBlank ?? "Checkout failed (exit \(result.exitCode))."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func stageAllChanges() async {
        guard activeBook.allowsPatchGitCommands else {
            statusMessage = "Enable Allow patch apply or Allow shell commands in book Settings."
            return
        }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            let result = try await PatchApplier().gitStageAll(book: activeBook)
            if result.exitCode == 0 {
                statusMessage = "Staged all changes."
                await refreshGitState()
            } else {
                statusMessage = result.combinedOutput.nilIfBlank ?? "Stage failed (exit \(result.exitCode))."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func commitChanges() async {
        guard activeBook.allowsPatchGitCommands else {
            statusMessage = "Enable Allow patch apply or Allow shell commands in book Settings."
            return
        }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            statusMessage = "Enter a commit message."
            return
        }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            let paths = allChangedPaths
            let result = try await PatchApplier().gitCommit(message: message, changedPaths: paths, book: activeBook)
            if result.exitCode == 0 {
                statusMessage = "Committed successfully."
                commitMessage = ""
                await refreshGitState()
            } else {
                statusMessage = result.combinedOutput.nilIfBlank ?? "Commit failed (exit \(result.exitCode))."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func copyCommitCommand() {
        let paths = allChangedPaths
        let command = PatchApplier.suggestedCommitCommand(
            message: commitMessage.isEmpty ? "<message>" : commitMessage,
            changedPaths: paths,
            book: activeBook
        )
        FileHelpers.copyToPasteboard(command)
        statusMessage = "Copied git add / commit commands to the clipboard."
    }
}
