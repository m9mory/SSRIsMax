import Foundation

/// Хранилище учётных данных в памяти — для CLI и SPM-тестов.
///
/// Приложение использует `KeychainCredentialStore`, но тот тянет
/// Security.framework, поэтому в зеркале ядра его нет. Протокол
/// `MaxCredentialStore` живёт здесь, чтобы `MaxAuthService` собирался
/// одинаково и в приложении, и в CLI.
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

/// Простое хранилище «как Keychain, только без него».
public final class MaxMemoryCredentialStore: MaxCredentialStore, @unchecked Sendable {
    public var deviceID: String
    public var accessToken: String?
    public var currentUserID: MaxUserID?

    private var profile: MaxUser?

    public init(deviceID: String = UUID().uuidString.lowercased(),
                accessToken: String? = nil,
                currentUserID: MaxUserID? = nil) {
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.currentUserID = currentUserID
    }

    public func clearSession() {
        accessToken = nil
        currentUserID = nil
        profile = nil
    }

    public func cacheProfile(_ user: MaxUser) {
        profile = user
    }

    public func cachedProfile() throws -> MaxUser? {
        profile
    }
}
