import Foundation
import Security

enum KeychainStore {
    private static let legacyService = "com.bookloop.app"
    private static let legacyAccount = "openai-api-key"
    private static let secretsDirectoryName = "secrets"
    private static let secretFileName = "openai-api-key"

    static func saveOpenAIAPIKey(_ key: String) throws {
        try writeToSecureFile(key)
        deleteLegacyKeychainItem()
    }

    static func loadOpenAIAPIKey() -> String? {
        if let fromFile = readFromSecureFile() {
            return fromFile
        }
        return migrateLegacyKeychainItem()
    }

    static func deleteOpenAIAPIKey() {
        deleteSecureFile()
        deleteLegacyKeychainItem()
    }

    private static func secretsDirectoryURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw KeychainError.storageUnavailable
        }
        return base.appendingPathComponent("BookLoop", isDirectory: true)
            .appendingPathComponent(secretsDirectoryName, isDirectory: true)
    }

    private static func secretFileURL() throws -> URL {
        try secretsDirectoryURL().appendingPathComponent(secretFileName, isDirectory: false)
    }

    private static func writeToSecureFile(_ key: String) throws {
        let url = try secretFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(key.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    private static func readFromSecureFile() -> String? {
        guard let url = try? secretFileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func deleteSecureFile() {
        guard let url = try? secretFileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func migrateLegacyKeychainItem() -> String? {
        guard let legacy = readLegacyKeychainItem() else { return nil }
        try? writeToSecureFile(legacy)
        deleteLegacyKeychainItem()
        return legacy
    }

    private static func readLegacyKeychainItem() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func deleteLegacyKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case storageUnavailable
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Could not access BookLoop application support storage."
        case .unhandled(let status):
            return "Key storage error (\(status))."
        }
    }
}
