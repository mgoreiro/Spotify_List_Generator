import Foundation
import Security

/// Llavero con caché en memoria: cada secreto se lee del Llavero como mucho una vez por ejecución y
/// se actualiza in situ (SecItemUpdate) para conservar el elemento y su "Permitir siempre".
enum Keychain {
    private static let service = "com.miguel.SpotifyListGenerator"
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// Devuelve false si el Llavero rechazó la operación (la caché no se modifica en ese caso).
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let q = query(key)
        var status: OSStatus
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = q
                item[kSecValueData as String] = data
                status = SecItemAdd(item as CFDictionary, nil)
            }
            if status == errSecSuccess { cache[key] = .some(value) }
        } else {
            status = SecItemDelete(q as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { cache[key] = .some(nil); status = errSecSuccess }
        }
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        let value = (status == errSecSuccess) ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        if status == errSecSuccess || status == errSecItemNotFound { cache[key] = .some(value) }
        return value
    }
}
