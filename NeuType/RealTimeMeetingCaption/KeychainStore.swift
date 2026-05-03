import Foundation
import Security

enum KeychainStore {
    static func string(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    static func setString(_ value: String?, service: String, account: String) {
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var insertion = query
                insertion[kSecValueData as String] = data
                _ = SecItemAdd(insertion as CFDictionary, nil)
            }
            return
        }

        delete(service: service, account: account)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

enum LiveMeetingCaptionCredentialsStore {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "NeuType").live-meeting-captions"
    private static let subscriptionKeyAccount = "azure.liveMeetingCaptions.subscriptionKey"
    private static let regionAccount = "azure.liveMeetingCaptions.region"

    static var subscriptionKey: String {
        get { KeychainStore.string(service: service, account: subscriptionKeyAccount) ?? "" }
        set { KeychainStore.setString(newValue, service: service, account: subscriptionKeyAccount) }
    }

    static var region: String {
        get { KeychainStore.string(service: service, account: regionAccount) ?? "" }
        set { KeychainStore.setString(newValue, service: service, account: regionAccount) }
    }
}
