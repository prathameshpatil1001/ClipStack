//
//  KeychainSecretStore.swift
//  ClipStack
//
//  Secret profile values (a PRN, an API token) in the login Keychain, one
//  generic-password item per detail, keyed by the detail's id. They are never
//  written to ClipStack's own files.
//

import Foundation
import Security

struct KeychainSecretStore: SecretStore {

    private let service = "com.prathamesh.ClipStack.profile"

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    func read(_ id: UUID) -> String? {
        var request = query(for: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String, for id: UUID) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query(for: id) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return status == errSecSuccess }

        var item = query(for: id)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "ClipStack profile detail"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
    }
}
