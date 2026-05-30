import AppKit
import Foundation

struct FigureAssetFetchResult: Equatable {
    var data: Data
    var contentType: String?
    var suggestedExtension: String
    var sourceURL: String
}

enum FigurePatchError: LocalizedError {
    case emptyAsset
    case invalidFigureID
    case noStagingOutput
    case scriptFailed(String)
    case patchExportFailed(String)
    case unsupportedContentType(String)
    case blockedHost(String)

    var errorDescription: String? {
        switch self {
        case .emptyAsset: return "No figure asset data is available."
        case .invalidFigureID: return "Enter a valid figure ID (letters, numbers, and dashes)."
        case .noStagingOutput: return "Script preview did not produce an output file."
        case .scriptFailed(let detail): return detail
        case .patchExportFailed(let detail): return detail
        case .unsupportedContentType(let type): return "Unsupported content type: \(type)"
        case .blockedHost(let host): return "Blocked host: \(host). Only public HTTPS URLs are allowed."
        }
    }
}

enum FigureAssetFetcher {
    static let defaultMaxBytes = 10_485_760

    static func fetchImage(urlString: String, maxBytes: Int = defaultMaxBytes) async throws -> FigureAssetFetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            throw AgentURLFetcherError.nonHTTPS
        }
        try validateHost(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("BookLoop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*,image/svg+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AgentURLFetcherError.requestFailed("HTTP \(code)")
        }
        guard !data.isEmpty else { throw FigurePatchError.emptyAsset }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ext = extensionForContentType(contentType, url: url, data: data)
        guard ext != "unknown" else {
            throw FigurePatchError.unsupportedContentType(contentType ?? "unknown")
        }

        let capped = data.count > maxBytes ? Data(data.prefix(maxBytes)) : data
        return FigureAssetFetchResult(
            data: capped,
            contentType: contentType,
            suggestedExtension: ext,
            sourceURL: trimmed
        )
    }

    private static func extensionForContentType(_ contentType: String?, url: URL, data: Data) -> String {
        if let contentType {
            if contentType.contains("svg") { return "svg" }
            if contentType.contains("png") { return "png" }
            if contentType.contains("jpeg") || contentType.contains("jpg") { return "jpg" }
            if contentType.contains("gif") { return "gif" }
            if contentType.contains("pdf") { return "pdf" }
            if contentType.contains("webp") { return "webp" }
        }
        let urlExt = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "svg", "gif", "pdf", "webp"].contains(urlExt) {
            return urlExt == "jpeg" ? "jpg" : urlExt
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: Data("<svg".utf8)) || data.starts(with: Data("<?xml".utf8)) { return "svg" }
        return "unknown"
    }

    private static func validateHost(_ url: URL) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw AgentURLFetcherError.invalidURL
        }
        if host == "localhost" || host.hasSuffix(".local") || host == "0.0.0.0" { throw FigurePatchError.blockedHost(host) }
        if host == "::1" || host.hasPrefix("127.") { throw FigurePatchError.blockedHost(host) }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { throw FigurePatchError.blockedHost(host) }
        if host.hasPrefix("172.") {
            let octets = host.split(separator: ".")
            if octets.count >= 2, let second = Int(octets[1]), (16...31).contains(second) {
                throw FigurePatchError.blockedHost(host)
            }
        }
    }
}

struct FigureScriptPreviewResult: Equatable {
    var stagingRoot: URL
    var outputRelativePath: String
    var outputAbsolutePath: String
    var sourceRelativePaths: [String]
    var commandOutput: String
}

enum FigureScriptRunner {
    static func preview(
        draft: FigureProposalDraft,
        book: BookConfig,
        scriptBody: String,
        command: String
    ) async throws -> FigureScriptPreviewResult {
        guard book.allowShellCommands, book.allowFigureRegeneration else {
            throw FigurePatchError.scriptFailed("Enable Allow shell commands and Allow figure regeneration in book Settings.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try book.withSecurityScopedProjectRoot {
                let projectRoot = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
                let stagingRoot = projectRoot
                    .appendingPathComponent(".bookloop/figure-staging", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

                let ext = "png"
                let outputRelative = draft.outputRelativePath(book: book, fileExtension: ext)
                let sourceRelative = "figures/\(draft.id)/source.\(scriptExtension(for: draft.sourceKind))"
                let sourceURL = stagingRoot.appendingPathComponent(sourceRelative)
                try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try scriptBody.write(to: sourceURL, atomically: true, encoding: .utf8)

                let outputURL = stagingRoot.appendingPathComponent(outputRelative)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let resolvedCommand = command
                    .replacingOccurrences(of: "<figure-id>", with: draft.id)
                    .replacingOccurrences(of: "<output-path>", with: outputURL.path)
                    .replacingOccurrences(of: "<source-path>", with: sourceURL.path)
                    .replacingOccurrences(of: "<staging-root>", with: stagingRoot.path)

                let runner = ProcessRunner()
                let result = try runner.run(
                    command: resolvedCommand,
                    workingDirectory: stagingRoot,
                    timeoutSeconds: 45
                )

                guard FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw FigurePatchError.scriptFailed(
                        "Command finished (exit \(result.exitCode)) but output was not created at \(outputRelative).\n\(result.combinedOutput)"
                    )
                }

                return FigureScriptPreviewResult(
                    stagingRoot: stagingRoot,
                    outputRelativePath: outputRelative,
                    outputAbsolutePath: outputURL.path,
                    sourceRelativePaths: [sourceRelative],
                    commandOutput: result.combinedOutput
                )
            }
        }.value
    }

    static func defaultScript(for kind: FigureSourceKind, figureID: String) -> String {
        switch kind {
        case .mermaid:
            return """
            flowchart LR
              A[\(figureID)] --> B[Update labels]
            """
        case .jsScript:
            return """
            // Write output to process.env.OUTPUT_PATH or docs/assets/figures/\(figureID).png under staging root
            console.log('Figure script for \(figureID)');
            """
        case .pythonScript:
            return """
            # matplotlib example — writes PNG to OUTPUT_PATH env var when set
            import os
            print("Figure script for \(figureID)")
            """
        default:
            return ""
        }
    }

    static func defaultCommand(for kind: FigureSourceKind, book: BookConfig) -> String {
        switch kind {
        case .mermaid:
            return "npx -y @mermaid-js/mermaid-cli -i \"<source-path>\" -o \"<output-path>\""
        case .jsScript:
            return book.figureGenerationCommand ?? "node \"<source-path>\""
        case .pythonScript:
            return book.figureGenerationCommand ?? "python3 \"<source-path>\""
        default:
            return book.figureGenerationCommand ?? ""
        }
    }

    private static func scriptExtension(for kind: FigureSourceKind) -> String {
        switch kind {
        case .mermaid: return "mmd"
        case .jsScript: return "js"
        case .pythonScript: return "py"
        default: return "txt"
        }
    }
}

enum PatchDiffGenerator {
    static func diffText(relativePath: String, oldText: String?, newText: String, projectRoot: URL) throws -> String {
        let runner = ProcessRunner()
        let staging = projectRoot.appendingPathComponent(".bookloop/patch-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let oldFile = staging.appendingPathComponent("old")
        let newFile = staging.appendingPathComponent("new")
        try (oldText ?? "").write(to: oldFile, atomically: true, encoding: .utf8)
        try newText.write(to: newFile, atomically: true, encoding: .utf8)

        let result = try runner.runGit(
            ["diff", "--no-index", "--", oldFile.path, newFile.path],
            workingDirectory: projectRoot
        )
        let diffText = result.stdout.isEmpty ? result.stderr : result.stdout
        return normalizeDiffPaths(in: diffText, relativePath: relativePath)
    }

    static func diffBinary(relativePath: String, newData: Data, projectRoot: URL) throws -> String {
        let runner = ProcessRunner()
        let staging = projectRoot.appendingPathComponent(".bookloop/patch-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let nullFile = staging.appendingPathComponent("empty")
        let newFile = staging.appendingPathComponent("new")
        try Data().write(to: nullFile)
        try newData.write(to: newFile)

        let result = try runner.runGit(
            ["diff", "--no-index", "--binary", "--", nullFile.path, newFile.path],
            workingDirectory: projectRoot
        )
        let diffText = result.stdout.isEmpty ? result.stderr : result.stdout
        return normalizeDiffPaths(in: diffText, relativePath: relativePath)
    }

    private static func normalizeDiffPaths(in diff: String, relativePath: String) -> String {
        let normalizedPath = relativePath.replacingOccurrences(of: "\\", with: "/")
        var lines = diff.components(separatedBy: .newlines).filter { !$0.hasPrefix("index ") }
        for index in lines.indices {
            if lines[index].hasPrefix("diff --git ") {
                lines[index] = "diff --git a/\(normalizedPath) b/\(normalizedPath)"
            } else if lines[index].hasPrefix("--- ") {
                lines[index] = lines[index].contains("empty") ? "--- /dev/null" : "--- a/\(normalizedPath)"
            } else if lines[index].hasPrefix("+++ ") {
                lines[index] = "+++ b/\(normalizedPath)"
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum FigureRegistryEditor {
    static func mergeEntry(into book: BookConfig, entry: [String: Any]) throws -> String {
        let relativePath = book.figuresRegistryPath.map { path -> String in
            if path.hasPrefix("/") { return path }
            return path
        } ?? book.suggestedPath("bookloop/figures.json")
        let absolute = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            .appendingPathComponent(relativePath.replacingOccurrences(of: "\\", with: "/"))

        var root: [String: Any]
        if let data = try? Data(contentsOf: absolute),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else if let data = try? Data(contentsOf: absolute),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            root = ["figures": array]
        } else {
            root = ["figures": []]
        }

        var figures = root["figures"] as? [[String: Any]] ?? []
        if let nested = root["items"] as? [[String: Any]] { figures = nested }

        let entryID = entry["id"] as? String ?? entry["figureID"] as? String ?? ""
        if let index = figures.firstIndex(where: {
            ($0["id"] as? String) == entryID || ($0["figureID"] as? String) == entryID
        }) {
            var merged = figures[index]
            for (key, value) in entry { merged[key] = value }
            figures[index] = merged
        } else {
            figures.append(entry)
        }

        root["figures"] = figures
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw FigurePatchError.patchExportFailed("Could not encode figures.json")
        }
        return json + "\n"
    }
}

final class FigurePatchBuilder {
    struct BuildResult {
        var patchURL: URL
        var patchProposal: PatchProposal
    }

    func build(
        book: BookConfig,
        draft: FigureProposalDraft,
        assetData: Data,
        assetExtension: String,
        extraSourceFiles: [FigureStagedFile] = []
    ) throws -> BuildResult {
        guard !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FigurePatchError.invalidFigureID
        }
        guard !assetData.isEmpty else { throw FigurePatchError.emptyAsset }

        return try book.withSecurityScopedProjectRoot {
            let projectRoot = URL(fileURLWithPath: book.projectRootPath, isDirectory: true)
            var patchParts: [String] = [
                "# BookLoop Figure Proposal",
                "# figure-id: \(draft.id)",
                "# source-kind: \(draft.sourceKind.rawValue)",
            ]
            if let sourceURL = draft.sourceURL?.nilIfBlank {
                patchParts.append("# source-url: \(sourceURL)")
            }
            if let attribution = draft.attribution?.nilIfBlank {
                patchParts.append("# attribution: \(attribution)")
            }
            patchParts.append("")

            let outputRelative = draft.outputRelativePath(book: book, fileExtension: assetExtension)
            patchParts.append(try PatchDiffGenerator.diffBinary(
                relativePath: outputRelative,
                newData: assetData,
                projectRoot: projectRoot
            ))

            for source in extraSourceFiles where source.newText?.nilIfBlank != nil {
                patchParts.append("")
                patchParts.append(try PatchDiffGenerator.diffText(
                    relativePath: source.relativePath,
                    oldText: source.oldText,
                    newText: source.newText ?? "",
                    projectRoot: projectRoot
                ))
            }

            let registryRelative = book.figuresRegistryPath ?? book.suggestedPath("bookloop/figures.json")
            let registryAbsolute = projectRoot.appendingPathComponent(registryRelative)
            let oldRegistry = (try? String(contentsOf: registryAbsolute, encoding: .utf8)) ?? ""
            var registryEntry: [String: Any] = [
                "id": draft.id,
                "outputPath": outputRelative,
                "chapterID": draft.chapterID ?? "",
                "caption": draft.caption,
                "altText": draft.altText,
                "sourceKind": draft.sourceKind.rawValue
            ]
            if let sourceURL = draft.sourceURL?.nilIfBlank { registryEntry["sourceURL"] = sourceURL }
            if let attribution = draft.attribution?.nilIfBlank { registryEntry["attribution"] = attribution }
            if let command = draft.generationCommand?.nilIfBlank { registryEntry["generationCommand"] = command }
            if let firstSource = extraSourceFiles.first?.relativePath { registryEntry["sourcePath"] = firstSource }

            let newRegistry = try FigureRegistryEditor.mergeEntry(into: book, entry: registryEntry)
            patchParts.append("")
            patchParts.append(try PatchDiffGenerator.diffText(
                relativePath: registryRelative,
                oldText: oldRegistry.nilIfBlank == nil ? nil : oldRegistry,
                newText: newRegistry,
                projectRoot: projectRoot
            ))

            if draft.insertMarkdown, let markdownRelative = resolveMarkdownPath(draft: draft, book: book) {
                let markdownAbsolute = projectRoot.appendingPathComponent(markdownRelative)
                let oldMarkdown = (try? String(contentsOf: markdownAbsolute, encoding: .utf8)) ?? ""
                let imageRef = markdownImageReference(
                    alt: draft.altText.nilIfBlank ?? draft.caption.nilIfBlank ?? draft.id,
                    assetRelativePath: outputRelative,
                    markdownRelativePath: markdownRelative
                )
                let newMarkdown = oldMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? imageRef + "\n"
                    : oldMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + imageRef + "\n"
                patchParts.append("")
                patchParts.append(try PatchDiffGenerator.diffText(
                    relativePath: markdownRelative,
                    oldText: oldMarkdown.nilIfBlank == nil ? nil : oldMarkdown,
                    newText: newMarkdown,
                    projectRoot: projectRoot
                ))
            }

            let rawPatch = patchParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            guard rawPatch.contains("diff --git") else {
                throw FigurePatchError.patchExportFailed("Could not generate figure patch.")
            }

            let patchesDirectory = URL(fileURLWithPath: book.patchDirectoryPath, isDirectory: true)
            try FileHelpers.ensureDirectory(patchesDirectory.path)
            let filename = "figure-\(DateFormatting.taskFilename.string(from: Date()))-\(draft.id.slugified()).patch"
            let patchURL = patchesDirectory.appendingPathComponent(filename)
            try rawPatch.write(to: patchURL, atomically: true, encoding: .utf8)

            let previewSidecar = patchURL.deletingPathExtension().appendingPathExtension(assetExtension)
            try assetData.write(to: previewSidecar)

            let proposal = PatchProposal(
                id: UUID(),
                filePath: patchURL.path,
                title: patchURL.deletingPathExtension().lastPathComponent,
                summary: "Figure proposal for \(draft.id) (\(draft.sourceKind.displayName))",
                createdAt: Date(),
                changedFiles: changedFiles(from: rawPatch),
                rawPatch: rawPatch
            )
            return BuildResult(patchURL: patchURL, patchProposal: proposal)
        }
    }

    private func changedFiles(from rawPatch: String) -> [String] {
        rawPatch.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("+++ b/") else { return nil }
            let path = String(line.dropFirst("+++ b/".count))
            return path == "/dev/null" ? nil : path
        }
    }

    private func resolveMarkdownPath(draft: FigureProposalDraft, book: BookConfig) -> String? {
        if let explicit = draft.targetMarkdownPath?.nilIfBlank {
            return explicit.replacingOccurrences(of: "\\", with: "/")
        }
        guard let chapterID = draft.chapterID?.nilIfBlank else { return nil }
        let docsPath = book.docsPath ?? book.suggestedPath("docs")
        let docsURL = URL(fileURLWithPath: docsPath, isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                if url.deletingPathExtension().lastPathComponent == chapterID {
                    return relativePath(url.path, root: book.projectRootPath)
                }
            }
        }
        let fallback = docsURL.appendingPathComponent("\(chapterID).md")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return relativePath(fallback.path, root: book.projectRootPath)
        }
        return "docs/\(chapterID).md"
    }

    private func markdownImageReference(alt: String, assetRelativePath: String, markdownRelativePath: String) -> String {
        let upCount = markdownRelativePath.split(separator: "/").dropLast().count
        let prefix = Array(repeating: "..", count: upCount).joined(separator: "/")
        let assetPath = assetRelativePath.split(separator: "/").joined(separator: "/")
        let relative = prefix.isEmpty ? assetPath : "\(prefix)/\(assetPath)"
        return "![\(alt)](\(relative))"
    }

    private func relativePath(_ absolute: String, root: String) -> String {
        let rootPath = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return absolute }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

enum BinaryPatchPreviewExtractor {
    static func writePreview(from rawSection: String, to directory: URL) -> String? {
        guard rawSection.contains("GIT binary patch") || rawSection.contains("Binary files") else { return nil }
        let lines = rawSection.components(separatedBy: .newlines)
        guard let literalIndex = lines.firstIndex(where: { $0.hasPrefix("literal ") }) else { return nil }
        guard let length = Int(lines[literalIndex].replacingOccurrences(of: "literal ", with: "")) else { return nil }

        var data = Data()
        var index = literalIndex + 1
        while index < lines.count, data.count < length {
            let line = lines[index]
            if line.hasPrefix("literal ") || line.hasPrefix("delta ") || line.isEmpty {
                break
            }
            if let chunk = decodeLiteralLine(line) {
                data.append(chunk)
            }
            index += 1
        }

        guard !data.isEmpty else { return nil }
        let url = directory.appendingPathComponent("preview-\(UUID().uuidString).bin")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url)
        return url.path
    }

    private static func decodeLiteralLine(_ line: String) -> Data? {
        Data(base64Encoded: line) ?? line.data(using: .utf8)
    }
}
