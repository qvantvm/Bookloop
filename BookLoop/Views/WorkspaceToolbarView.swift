import SwiftUI

struct WorkspaceToolbarView: View {
    @Binding var workspaceMode: WorkspaceMode
    @Binding var showingAppSettings: Bool

    var body: some View {
        VStack(spacing: 6) {
            toolbarButton(
                icon: "book.fill",
                isSelected: workspaceMode == .reading,
                help: "Reading"
            ) {
                workspaceMode = .reading
            }

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            ForEach(WorkspaceTab.toolTabs) { tab in
                toolbarButton(
                    icon: tab.toolbarIcon,
                    isSelected: isToolSelected(tab),
                    help: tab.rawValue
                ) {
                    workspaceMode = .tool(tab)
                }
            }

            Spacer(minLength: 0)

            toolbarButton(
                icon: "slider.horizontal.3",
                isSelected: false,
                help: "App Settings"
            ) {
                showingAppSettings = true
            }
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }

    private func toolbarButton(
        icon: String,
        isSelected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func isToolSelected(_ tab: WorkspaceTab) -> Bool {
        if case .tool(let selected) = workspaceMode {
            return selected == tab
        }
        return false
    }
}

extension WorkspaceTab {
    static var toolTabs: [WorkspaceTab] {
        [.search, .reviews, .tasks, .agent, .patches, .figures, .settings]
    }

    var toolbarIcon: String {
        switch self {
        case .preview: return "book.fill"
        case .agent: return "cpu"
        case .search: return "magnifyingglass"
        case .reviews: return "quote.bubble"
        case .figures: return "photo"
        case .tasks: return "checklist"
        case .patches: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}
