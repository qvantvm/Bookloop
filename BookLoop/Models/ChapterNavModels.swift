import Foundation

struct ChapterNavItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let href: String
    let children: [ChapterNavItem]

    init(id: String? = nil, title: String, href: String, children: [ChapterNavItem] = []) {
        self.title = title
        self.href = href
        self.id = id ?? (href.isEmpty ? title : href)
        self.children = children
    }

    var isNavigable: Bool {
        !href.isEmpty && href != "#"
    }
}

extension ChapterNavItem {
    static func firstNavigablePath(in items: [ChapterNavItem]) -> String? {
        for item in items {
            if item.isNavigable { return item.href }
            if let child = firstNavigablePath(in: item.children) { return child }
        }
        return nil
    }
}
