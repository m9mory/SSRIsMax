import Foundation
import Security

/// Долговременное хранилище (UserDefaults + Keychain).
///
/// Токен и deviceId — секреты: Keychain. Настройки — UserDefaults.
public protocol MaxCredentialStore: AnyObject {
    var deviceID: String { get }
    var accessToken: String? { get set }
    var currentUserID: MaxUserID? { get set }
    func clearSession()

    /// Кеш профиля: онлайн-соединение не делает повторный LOGIN,
    /// поэтому имя и телефон для UI берутся отсюда.
    func cacheProfile(_ user: MaxUser)
    func cachedProfile() throws -> MaxUser?
}

public extension MaxCredentialStore {
    func cacheProfile(_ user: MaxUser) {}
    func cachedProfile() throws -> MaxUser? { nil }
}

public final class KeychainCredentialStore: MaxCredentialStore, @unchecked Sendable {
    private let keychain = KeychainService(service: "ru.maxclient.app.session")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var deviceID: String {
        if let existing = keychain.string(for: "deviceID") { return existing }
        let generated = UUID().uuidString.lowercased()
        keychain.set(generated, for: "deviceID")
        return generated
    }

    public var accessToken: String? {
        get { keychain.string(for: "accessToken") }
        set {
            if let newValue { keychain.set(newValue, for: "accessToken") }
            else { keychain.delete("accessToken") }
        }
    }

    public var currentUserID: MaxUserID? {
        get {
            guard let raw = defaults.object(forKey: "max.currentUserID") else { return nil }
            if let number = raw as? NSNumber { return number.int64Value }
            return (raw as? String).flatMap(Int64.init)
        }
        set {
            if let newValue { defaults.set(NSNumber(value: newValue), forKey: "max.currentUserID") }
            else { defaults.removeObject(forKey: "max.currentUserID") }
        }
    }

    public func clearSession() {
        keychain.delete("accessToken")
        keychain.delete("profile")
        currentUserID = nil
    }

    // MARK: Профиль в кеше

    private struct CachedProfile: Codable {
        var id: MaxUserID
        var firstName: String?
        var lastName: String?
        var fullName: String
        var phoneNumber: String?
        var about: String?
        var avatarURL: String?
        var isBot: Bool
    }

    public func cacheProfile(_ user: MaxUser) {
        let cached = CachedProfile(id: user.id,
                                   firstName: user.firstName,
                                   lastName: user.lastName,
                                   fullName: user.fullName,
                                   phoneNumber: user.phoneNumber,
                                   about: user.about,
                                   avatarURL: user.avatarURL?.absoluteString,
                                   isBot: user.isBot)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        // Профиль содержит телефон — держим его в Keychain, не в plist.
        keychain.set(String(decoding: data, as: UTF8.self), for: "profile")
    }

    public func cachedProfile() throws -> MaxUser? {
        guard let text = keychain.string(for: "profile"),
              let data = text.data(using: .utf8) else { return nil }
        let cached = try JSONDecoder().decode(CachedProfile.self, from: data)
        return MaxUser(id: cached.id,
                       firstName: cached.firstName,
                       lastName: cached.lastName,
                       fullName: cached.fullName,
                       phoneNumber: cached.phoneNumber,
                       about: cached.about,
                       avatarURL: cached.avatarURL.flatMap(URL.init(string:)),
                       isBot: cached.isBot)
    }
}

/// Обёртка над Security.framework для iOS и macOS.
public final class KeychainService {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func set(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
