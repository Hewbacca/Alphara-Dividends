import Foundation
import Security

/// Minimal Keychain wrapper for storing the user's Polygon API key.
///
/// We store the key in the Keychain rather than UserDefaults so it is not trivially
/// readable from a device backup, and never embed a shared key in the app binary.
enum KeychainStore {
    private static let service = "com.alphara.dividends"
    private static let account = "polygon-api-key"

    static var apiKey: String? {
        get { read(account: account) }
        set {
            if let newValue, !newValue.isEmpty {
                write(account: account, value: newValue)
            } else {
                delete(account: account)
            }
        }
    }

    // MARK: - Generic helpers

    private static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
