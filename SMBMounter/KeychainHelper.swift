import Foundation
import Security

class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.smbmounter.passwords"
    
    @discardableResult
    func savePassword(_ password: String, for shareID: UUID) -> Bool {
        let account = shareID.uuidString
        let data = Data(password.utf8)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
    
    func getPassword(for shareID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            var legacyQuery = query
            legacyQuery[kSecUseDataProtectionKeychain as String] = false
            var legacyResult: AnyObject?
            guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
                  let data = legacyResult as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            if savePassword(password, for: shareID) {
                var verificationQuery = query
                verificationQuery[kSecReturnData as String] = true
                var verified: AnyObject?
                if SecItemCopyMatching(verificationQuery as CFDictionary, &verified) == errSecSuccess,
                   verified as? Data == data {
                    legacyQuery.removeValue(forKey: kSecReturnData as String)
                    legacyQuery.removeValue(forKey: kSecMatchLimit as String)
                    SecItemDelete(legacyQuery as CFDictionary)
                }
            }
            return password
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }
    
    func deletePassword(for shareID: UUID) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecUseDataProtectionKeychain as String] = false
        SecItemDelete(query as CFDictionary)
    }
}
