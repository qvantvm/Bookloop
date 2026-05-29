import Foundation

struct PreviewSelectionQuote: Codable, Equatable {
    var exact: String
    var prefix: String
    var suffix: String
}

struct PreviewAnnotation: Identifiable, Codable, Equatable {
    var id: UUID
    var chapterPath: String
    var chapterID: String?
    var exact: String
    var prefix: String
    var suffix: String
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var quote: PreviewSelectionQuote {
        PreviewSelectionQuote(exact: exact, prefix: prefix, suffix: suffix)
    }
}

struct PreviewAnnotationDocument: Codable {
    var version: Int
    var annotations: [PreviewAnnotation]

    static let currentVersion = 1

    static func empty() -> PreviewAnnotationDocument {
        PreviewAnnotationDocument(version: currentVersion, annotations: [])
    }
}
