import SwiftUI

@main
struct BookLoopApp: App {
    @StateObject private var library = BookLibraryStore()
    @StateObject private var settingsStore = AppSettingsStore()

    var body: some Scene {
        WindowGroup("BookLoop") {
            ContentView()
                .environmentObject(library)
                .environmentObject(settingsStore)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Preview") {
                    NotificationCenter.default.post(name: .bookLoopReloadPreview, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let bookLoopReloadPreview = Notification.Name("BookLoopReloadPreview")
    static let bookLoopRefreshAnnotations = Notification.Name("BookLoopRefreshAnnotations")
}
