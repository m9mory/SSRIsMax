import Foundation

/// Хранилище учётных данных в памяти — для CLI и SPM-тестов.
///
/// Приложение использует `KeychainCredentialStore` (Security.framework),
/// поэтому тот файл в зеркало не копируется. Протокол `MaxCredentialStore`
/// тоже НЕ объявляется здесь: его единственный источник истины —
/// `MaxClient/Core/Storage/CredentialStore.swift`, а в CLI-пакет он
/// попадает через копию `Core/CredentialStore.swift`. Дублировать
/// декларацию в двух файлах одного модуля нельзя — будет
/// `invalid redeclaration of 'MaxCredentialStore'`.
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
