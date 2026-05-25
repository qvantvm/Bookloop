import Foundation

enum ProjectPathGuardError: LocalizedError {
    case emptyPath
    case absolutePath
    case traversal
    case outsideProject
    case protected(String)
    case writeNotAllowed(String)
    case fileTooLarge(Int)
    case notAFile
    case binaryFile

    var errorDescription: String? {
        switch self {
        case .emptyPath: return "Path is required."
        case .absolutePath: return "Absolute paths are not allowed."
        case .traversal: return "Path traversal is not allowed."
        case .outsideProject: return "Path is outside the project root."
        case .protected(let path): return "Protected path cannot be accessed: \(path)"
        case .writeNotAllowed(let path): return "Writing is not allowed for: \(path)"
        case .fileTooLarge(let bytes): return "File exceeds size limit (\(bytes) bytes)."
        case .notAFile: return "Path is not a regular file."
        case .binaryFile: return "Binary files cannot be read."
        }
    }
}

struct ProjectPathGuard {
    let rootURL: URL
    let config: BookProjectConfig
    let maxReadBytes: Int

    init(rootURL: URL, config: BookProjectConfig, maxReadBytes: Int = 512_000) {
        self.rootURL = rootURL
        self.config = config
        self.maxReadBytes = maxReadBytes
    }

    func resolveRelativePath(_ rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectPathGuardError.emptyPath }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { throw ProjectPathGuardError.absolutePath }
        if trimmed.contains("..") { throw ProjectPathGuardError.traversal }

        let normalized = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let url = rootURL.appendingPathComponent(normalized)
        let root = rootURL.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw ProjectPathGuardError.outsideProject
        }
        return url
    }

    func relativePath(for url: URL) -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        return path
    }

    func validateRead(_ rawPath: String) throws -> URL {
        let url = try resolveRelativePath(rawPath)
        let relative = relativePath(for: url)
        if isProtected(relativePath: relative) { throw ProjectPathGuardError.protected(relative) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ProjectPathGuardError.notAFile
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.intValue > maxReadBytes {
            throw ProjectPathGuardError.fileTooLarge(size.intValue)
        }
        return url
    }

    func validateWrite(_ rawPath: String) throws -> URL {
        let url = try resolveRelativePath(rawPath)
        let relative = relativePath(for: url)
        if isProtected(relativePath: relative) { throw ProjectPathGuardError.protected(relative) }
        guard config.allowedWriteGlobs.contains(where: { GlobMatcher.matches(glob: $0, path: relative) }) else {
            throw ProjectPathGuardError.writeNotAllowed(relative)
        }
        return url
    }

    func isProtected(relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        return config.protectedPaths.contains { protected in
            let p = protected.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if p.isEmpty { return false }
            return normalized == p || normalized.hasPrefix(p + "/") || normalized.split(separator: "/").contains(Substring(p))
        }
    }

    func readText(at rawPath: String) throws -> String {
        let url = try validateRead(rawPath)
        let data = try Data(contentsOf: url)
        if data.contains(0) { throw ProjectPathGuardError.binaryFile }
        guard let text = String(data: data, encoding: .utf8) else { throw ProjectPathGuardError.binaryFile }
        return text
    }
}
