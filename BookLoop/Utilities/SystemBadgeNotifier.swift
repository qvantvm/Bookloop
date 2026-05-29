import AppKit
import Foundation
import UserNotifications

@MainActor
enum SystemBadgeNotifier {
    private static var didRequestAuthorization = false

    static func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func notifyAgentTaskCompleted(bookName: String, summary: String, createdPatch: Bool) {
        requestAuthorizationIfNeeded()

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmedSummary.isEmpty
            ? "The agent finished successfully."
            : String(trimmedSummary.prefix(180))

        let content = UNMutableNotificationContent()
        content.title = "Agent task completed"
        if createdPatch {
            content.body = "\(bookName): \(preview) Open Patches to review the new proposal."
        } else {
            content.body = "\(bookName): \(preview)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func updatePendingPatchBadge(count: Int) {
        if count > 0 {
            NSApplication.shared.dockTile.badgeLabel = count > 99 ? "99+" : "\(count)"
        } else {
            NSApplication.shared.dockTile.badgeLabel = nil
        }
    }
}
