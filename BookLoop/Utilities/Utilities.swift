import AppKit
import Foundation
import SwiftUI

enum DateFormatting {
    static let taskFilename: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let cumulativeReview: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

enum FileHelpers {
    static func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    static func openInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func openExternal(url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openFile(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func modificationDate(path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
    }
}

/// Ensures book-repo `.gitignore` excludes ephemeral BookLoop tooling files.
enum BookLoopGitignore {
    static let marker = "# BookLoop generated ignores"

    static let recommendedLines = [
        ".bookloop/sessions/",
        "bookloop/patches/archive/",
        "bookloop/patches/activity.json",
        "bookloop/patches/reviewed-*.patch"
    ]

    @discardableResult
    static func ensureEntries(in projectRoot: String) throws -> Bool {
        let gitignoreURL = URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        let missing = recommendedLines.filter { line in
            !existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line })
        }
        guard !missing.isEmpty else { return false }

        var newBlock = marker + "\n"
        newBlock += missing.map { $0 + "\n" }.joined()

        let combined: String
        if existing.isEmpty {
            combined = newBlock
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            combined = existing + separator + newBlock
        }
        try combined.write(to: gitignoreURL, atomically: true, encoding: .utf8)
        return true
    }
}

enum ValidationCommandPolicy {
    /// BookLoop preview renders in Swift; mkdocs is not a supported validation command.
    static func isLegacyMkdocsCommand(_ command: String?) -> Bool {
        guard let raw = command?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        return raw.contains("mkdocs")
    }

    static func effective(_ command: String?) -> String? {
        guard let raw = command?.nilIfBlank, !isLegacyMkdocsCommand(raw) else { return nil }
        return raw
    }

    static func sanitized(_ command: String?) -> String? {
        effective(command)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func slugified() -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return lowercased()
            .map { character -> Character in
                guard let scalar = character.unicodeScalars.first else { return "-" }
                return allowed.contains(scalar) ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension URL {
    var detectedChapterSlug: String? {
        if isFileURL {
            let components = pathComponents
            if lastPathComponent == "index.html", components.count >= 2 {
                return components[components.count - 2]
            }
            return deletingPathExtension().lastPathComponent.nilIfBlank
        }
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmedPath.split(separator: "/").last else { return nil }
        return String(last).nilIfBlank
    }
}

struct StatusBadge: View {
    let title: String
    let status: LocalAPIStatus

    var body: some View {
        Label("\(title): \(status.label)", systemImage: "circle.fill")
            .foregroundStyle(color)
            .font(.caption)
            .labelStyle(.titleAndIcon)
    }

    private var color: Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .checking: return .orange
        case .notConfigured: return .secondary
        case .unknown: return .gray
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "book"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum PathPicker {
    static func pickDirectory(title: String, initialPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let initialPath {
            panel.directoryURL = URL(fileURLWithPath: initialPath, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func pickFile(title: String, initialPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let initialPath {
            panel.directoryURL = URL(fileURLWithPath: initialPath).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
