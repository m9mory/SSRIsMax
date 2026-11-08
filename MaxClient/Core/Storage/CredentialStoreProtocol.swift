import Foundation

/// Хранилище учётных данных и кеша профиля.
///
/// Единственный источник истины. Файл намеренно НЕ импортирует
/// Security.framework, чтобы попадать и в приложение, и в зеркало ядра
/// (`scripts/sync-core.ps1` копирует его как `Core/CredentialStoreProtocol.swift`).
/// Реализация для приложения — `KeychainCredentialStore` в
/// `Core/Storage/CredentialStore.swift`, для CLI —
/// `MaxMemoryCredentialStore` в `Tools/max-core/Core`.
///
/// Раньше протокол жил только в зеркале, и приложение не собиралось:
/// `cannot find type 'MaxCredentialStore' in scope`.
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
