import SwiftUI

struct PatchActionPanel: View {
    let book: BookConfig
    let proposal: PatchProposal?
    let pendingCommitContext: PendingPatchCommitContext?
    let blocks: [RenderedPatchBlock]
    @Binding var decisions: [String: PatchBlockDecision]
    let workflowPhase: PatchWorkflowPhase
    let activityLog: [PatchActivityEntry]
    let patchApplicabilityStatus: PatchApplicabilityStatus
    let isRunningPatchCommand: Bool
    @Binding var showAdvanced: Bool
    @Binding var commitMessage: String
    let statusMessage: String?
    let onApplyAccepted: () -> Void
    let onCommit: () -> Void
    let onCopyCommitCommand: () -> Void
    let onOpenPatchFile: () -> Void
    let onArchiveWithoutApplying: () -> Void
    let onCopyAcceptedPatch: () -> Void
    let onSaveAcceptedPatch: () -> Void
    let onCheckAcceptedPatch: () -> Void
    let onApplyFullPatch: () -> Void
    let onCheckFullPatch: () -> Void

    private var acceptedCount: Int { decisions.values.filter { $0 == .accepted }.count }
    private var rejectedCount: Int { decisions.values.filter { $0 == .rejected }.count }
    private var pendingCount: Int { blocks.count - acceptedCount - rejectedCount }

    private var isAlreadyApplied: Bool {
        workflowPhase == .alreadyApplied || {
            if case .alreadyApplied = patchApplicabilityStatus { return true }
            return false
        }()
    }

    private var canApply: Bool {
        book.allowPatchApply && acceptedCount > 0 && !isAlreadyApplied && workflowPhase == .reviewing && proposal != nil
    }

    private var canCommit: Bool {
        book.allowsPatchGitCommands && workflowPhase == .appliedToDisk && pendingCommitContext != nil
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var applyDisabledReason: String? {
        if workflowPhase == .appliedToDisk { return "Already applied to book — proceed to Step 3: Commit." }
        if workflowPhase == .committed { return "This patch workflow is complete." }
        if isAlreadyApplied { return "This patch was already applied to the book." }
        if !book.allowPatchApply { return "Enable Allow patch apply in book Settings." }
        if acceptedCount == 0 { return "Accept at least one block in Step 1." }
        if proposal == nil && pendingCommitContext == nil { return "Select a patch from the list." }
        return nil
    }

    private var commitDisabledReason: String? {
        if workflowPhase == .committed { return "Changes are already committed." }
        if workflowPhase != .appliedToDisk { return "Apply to book first (Step 2)." }
        if !book.allowsPatchGitCommands { return "Enable Allow patch apply or Allow shell commands in book Settings." }
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a commit message." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                workflowHeader

                stepCard(number: 1, title: "Review blocks", isActive: workflowPhase == .reviewing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(acceptedCount) accepted · \(rejectedCount) rejected · \(pendingCount) pending")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Review decisions choose what would change. Nothing is written to book files yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Center preview is a snapshot from the patch file.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        HStack {
                            Button("Accept All") { setAll(.accepted) }
                                .disabled(proposal == nil || blocks.isEmpty)
                            Button("Reject All") { setAll(.rejected) }
                                .disabled(proposal == nil || blocks.isEmpty)
                            Button("Reset") { decisions.removeAll() }
                                .disabled(proposal == nil || blocks.isEmpty)
                        }
                        if let proposal {
                            Text("Files: \(proposal.changedFiles.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                stepCard(number: 2, title: "Apply to book", isActive: workflowPhase == .appliedToDisk) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Writes accepted blocks to disk via git apply. Does not commit.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button(isRunningPatchCommand ? "Applying…" : "Apply Accepted Changes", role: .destructive) {
                            onApplyAccepted()
                        }
                        .disabled(isRunningPatchCommand || !canApply)
                        if let reason = applyDisabledReason, !canApply {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                stepCard(number: 3, title: "Commit to git", isActive: workflowPhase == .committed) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let context = pendingCommitContext, !context.evidenceFiles.isEmpty {
                            Text("Includes \(context.changedFiles.count) patched file(s) plus \(context.evidenceFiles.count) evidence file(s) (reviews/tasks).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(context.evidenceFiles, id: \.self) { path in
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        TextField("Commit message", text: $commitMessage)
                        Button(isRunningPatchCommand ? "Committing…" : "Commit to Git") {
                            onCommit()
                        }
                        .disabled(isRunningPatchCommand || !canCommit)
                        if let reason = commitDisabledReason, !canCommit {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !book.allowsPatchGitCommands {
                            Button("Copy Git Commit Command") { onCopyCommitCommand() }
                        }
                    }
                }

                if !activityLog.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(activityLog.prefix(6)) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(DateFormatting.display.string(from: entry.timestamp))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 72, alignment: .leading)
                                    Text(entry.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open Patch File") { onOpenPatchFile() }
                            .disabled(proposal == nil)
                        Button("Copy Git Commit Command") { onCopyCommitCommand() }
                        Button("Archive Without Applying") { onArchiveWithoutApplying() }
                            .disabled(proposal == nil)
                        Divider()
                        Button("Check Accepted-Blocks Patch") { onCheckAcceptedPatch() }
                            .disabled(proposal == nil || acceptedCount == 0 || isRunningPatchCommand)
                        Button("Copy Accepted-Blocks Patch") { onCopyAcceptedPatch() }
                            .disabled(proposal == nil || acceptedCount == 0)
                        Button("Save Accepted-Blocks Patch") { onSaveAcceptedPatch() }
                            .disabled(proposal == nil || acceptedCount == 0)
                        Button("Check Full Original Patch") { onCheckFullPatch() }
                            .disabled(proposal == nil || isRunningPatchCommand)
                        Button("Apply Full Original Patch", role: .destructive) { onApplyFullPatch() }
                            .disabled(proposal == nil || isRunningPatchCommand || !book.allowPatchApply || isAlreadyApplied)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workflowHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Patch Workflow")
                .font(.headline)
            HStack(spacing: 8) {
                phaseBadge("1 Review", active: workflowPhase == .reviewing)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                phaseBadge("2 Apply", active: workflowPhase == .appliedToDisk)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                phaseBadge("3 Commit", active: workflowPhase == .committed)
            }
            Text("Current: \(workflowPhase.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let proposal {
                Text(proposal.displayTitle)
                    .font(.subheadline.weight(.medium))
            } else if let pendingCommitContext {
                Text(pendingCommitContext.rootStem)
                    .font(.subheadline.weight(.medium))
                Text("Patch archived — finish commit below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseBadge(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.caption2.weight(active ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func stepCard(number: Int, title: String, isActive: Bool, @ViewBuilder content: () -> some View) -> some View {
        GroupBox {
            content()
                .padding(.vertical, 4)
        } label: {
            Label("Step \(number): \(title)", systemImage: isActive ? "largecircle.fill.circle" : "circle")
        }
    }

    private func setAll(_ decision: PatchBlockDecision) {
        decisions = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, decision) })
    }
}
