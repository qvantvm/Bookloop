import Foundation
import Security

enum KeychainStore {
    private static let service = "com.bookloop.app"
    private static let openAIKeyAccount = "openai-api-key"

    static func saveOpenAIAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        deleteOpenAIAPIKey()

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessControl as String] = try makeAccessControl()

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func loadOpenAIAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func deleteOpenAIAPIKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIKeyAccount
        ]
    }

    private static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [],
            &error
        ) else {
            let reason = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeychainError.accessControlFailed(reason)
        }
        return control
    }
}

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case accessControlFailed(String)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain error (\(status))."
        case .accessControlFailed(let reason):
            return "Keychain access control could not be created (\(reason))."
        }
    }
}
