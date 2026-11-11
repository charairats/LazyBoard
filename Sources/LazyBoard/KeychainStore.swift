import Foundation
import Security

/// Stores the Claude API key in the user's login keychain.
enum KeychainStore {
    private static let service = "com.jeancharairat.lazyboard"
    private static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        if let key = read(service: service) { return key }
        // Key saved while the app was still called ThaiTab.
        if let key = read(service: "com.jeen.thaitab") { write(key); return key }
        return nil
    }

    private static func read(service: String) -> String? {
        var q = query
        q[kSecAttrService as String] = service
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.write("keychain read failed (\(status))")
        }
        guard status == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves the key. Returns false when the keychain refused it (the key then lasts only until quit).
    @discardableResult
    static func write(_ value: String) -> Bool {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        } else if status != errSecSuccess {
            // An item made by an older build can refuse this build (ad-hoc signature changed): replace it.
            SecItemDelete(query as CFDictionary)
            var q = query
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        Log.write("keychain write: \(status == errSecSuccess ? "ok" : "failed (\(status))")")
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
