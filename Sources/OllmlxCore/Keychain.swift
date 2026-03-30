import Foundation
import Security

public enum Keychain {
    private static let service = "com.ollmlx.api-key"
    private static let account = "ollmlx"

    public static func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public static func setAPIKey(_ key: String?) throws {
        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let key, !key.isEmpty else {
            return // Just delete if nil or empty
        }

        guard let data = key.data(using: .utf8) else {
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError.writeFailed(status)
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case writeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let status):
            return "Keychain write failed with status: \(status)"
        }
    }
}
