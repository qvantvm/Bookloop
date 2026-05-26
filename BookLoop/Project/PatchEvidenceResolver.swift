import Foundation

struct PatchEvidence: Equatable {
    var reviewFiles: [String]
    var taskFiles: [String]

    var allPaths: [String] {
        var seen = Set<String>()
        return (reviewFiles + taskFiles).filter { seen.insert($0).inserted }
    }
}

enum PatchEvidenceResolver {
    private static let reviewIDPattern = #"\b(\d{8}-\d{6}-[a-z0-9-]+)\b"#
    private static let patchTimestampPattern = #"agent-(\d{8})-(\d{6})-"#
    private static let taskTimestampPattern = #"^(\d{8})-(\d{6})-"#

    static func resolve(book: BookConfig, proposal: PatchProposal) -> PatchEvidence {
        let patchDate = patchDate(from: proposal) ?? proposal.createdAt ?? Date()
        let sessionInstruction = sessionInstruction(for: proposal, book: book)
        let chapterSlugs = chapterSlugs(from: proposal.changedFiles)

        var reviewIDs = Set(reviewIDs(in: sessionInstruction))
        reviewIDs.formUnion(reviewIDsReferenced(inTasks: book, chapterSlugs: chapterSlugs, around: patchDate))

        var reviewFiles = reviewIDs.compactMap { reviewRelativePath(id: $0, book: book) }
        reviewFiles.append(contentsOf: reviewsForChapters(book: book, chapterSlugs: chapterSlugs, before: patchDate))
        reviewFiles = uniqueExistingRelativePaths(reviewFiles, book: book)

        let taskFiles = uniqueExistingRelativePaths(
            tasksForChapters(book: book, chapterSlugs: chapterSlugs, around: patchDate),
            book: book
        )

        return PatchEvidence(reviewFiles: reviewFiles, taskFiles: taskFiles)
    }

    private static func sessionInstruction(for proposal: PatchProposal, book: BookConfig) -> String {
        guard let sessionID = sessionID(from: proposal.rawPatch) else { return "" }
        let sessionDir = book.sessionsDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("request.json")
        guard let data = try? Data(contentsOf: sessionDir),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instruction = json["instruction"] as? String else {
            return ""
        }
        return instruction
    }

    private static func sessionID(from rawPatch: String) -> String? {
        let pattern = #"# Session:\s*([0-9A-Fa-f-]{36})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawPatch, range: NSRange(rawPatch.startIndex..., in: rawPatch)),
              let range = Range(match.range(at: 1), in: rawPatch) else {
            return nil
        }
        return String(rawPatch[range])
    }

    private static func patchDate(from proposal: PatchProposal) -> Date? {
        let name = URL(fileURLWithPath: proposal.filePath).lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: patchTimestampPattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let dateRange = Range(match.range(at: 1), in: name),
              let timeRange = Range(match.range(at: 2), in: name) else {
            return nil
        }
        let datePart = String(name[dateRange])
        let timePart = String(name[timeRange])
        return DateFormatting.taskFilename.date(from: "\(datePart)-\(timePart)")
    }

    private static func reviewIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: reviewIDPattern, options: .caseInsensitive) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func chapterSlugs(from changedFiles: [String]) -> [String] {
        changedFiles.compactMap { path in
            var normalized = path.replacingOccurrences(of: "\\", with: "/")
            while normalized.hasPrefix("docs/") {
                normalized = String(normalized.dropFirst("docs/".count))
            }
            while normalized.hasSuffix(".md") {
                normalized = String(normalized.dropLast(".md".count))
            }
            return normalized.nilIfBlank
        }
    }

    private static func reviewRelativePath(id: String, book: BookConfig) -> String? {
        let root = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
        let itemsDir = URL(fileURLWithPath: book.reviewItemsPath ?? book.suggestedPath("reviews/review_items"), isDirectory: true)
        let fileURL = itemsDir.appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return relativePath(for: fileURL.path, root: root.path)
    }

    private static func reviewsForChapters(book: BookConfig, chapterSlugs: [String], before patchDate: Date) -> [String] {
        guard !chapterSlugs.isEmpty,
              let items = try? ReviewItemParser().parseReviewItems(book: book) else {
            return []
        }
        let earliest = patchDate.addingTimeInterval(-48 * 60 * 60)
        let slugSet = Set(chapterSlugs)
        return items.compactMap { item -> String? in
            guard let chapter = item.chapter?.nilIfBlank, slugSet.contains(chapter) else { return nil }
            guard let createdAt = item.createdAt, createdAt <= patchDate.addingTimeInterval(60 * 60), createdAt >= earliest else {
                return nil
            }
            return relativePath(for: item.filePath, root: book.projectRootPath)
        }
    }

    private static func reviewIDsReferenced(inTasks book: BookConfig, chapterSlugs: [String], around patchDate: Date) -> [String] {
        tasksForChapters(book: book, chapterSlugs: chapterSlugs, around: patchDate).flatMap { relativePath in
            let absolute = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
                .appendingPathComponent(relativePath)
                .path
            guard let content = try? String(contentsOfFile: absolute, encoding: .utf8) else { return [] as [String] }
            return reviewIDs(in: content)
        }
    }

    private static func tasksForChapters(book: BookConfig, chapterSlugs: [String], around patchDate: Date) -> [String] {
        let taskDirectory = URL(fileURLWithPath: book.taskDirectoryPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: taskDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let slugSet = Set(chapterSlugs)
        let windowStart = patchDate.addingTimeInterval(-24 * 60 * 60)
        let windowEnd = patchDate.addingTimeInterval(60 * 60)

        return files.compactMap { url -> String? in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let filename = url.deletingPathExtension().lastPathComponent
            guard slugSet.contains(where: { filename.localizedCaseInsensitiveContains($0) }) else { return nil }
            guard let taskDate = taskDate(from: filename), taskDate >= windowStart, taskDate <= windowEnd else {
                return nil
            }
            return relativePath(for: url.path, root: book.projectRootPath)
        }
    }

    private static func taskDate(from filename: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: taskTimestampPattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let dateRange = Range(match.range(at: 1), in: filename),
              let timeRange = Range(match.range(at: 2), in: filename) else {
            return nil
        }
        return DateFormatting.taskFilename.date(from: "\(String(filename[dateRange]))-\(String(filename[timeRange]))")
    }

    private static func relativePath(for absolutePath: String, root: String) -> String {
        let rootPath = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return absolutePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private static func uniqueExistingRelativePaths(_ paths: [String], book: BookConfig) -> [String] {
        var seen = Set<String>()
        let root = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
        return paths.filter { relative in
            guard seen.insert(relative).inserted else { return false }
            let absolute = root.appendingPathComponent(relative).path
            return FileManager.default.fileExists(atPath: absolute)
        }.sorted()
    }
}

private extension BookConfig {
    var sessionsDirectory: URL {
        URL(fileURLWithPath: projectRootPath, isDirectory: true)
            .appendingPathComponent(".bookloop/sessions", isDirectory: true)
    }
}
