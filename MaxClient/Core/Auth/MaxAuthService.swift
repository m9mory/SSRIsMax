import Foundation

/// Авторизация MAX.
///
/// Сценарий: INIT (opcode 6) → VERIFICATION_REQUEST (17) → SMS-код →
/// CODE_ENTER (18) → токен → LOGIN (19). Токен живёт долго, его храним
/// в Keychain и при следующем запуске сразу делаем LOGIN.
///
/// Важно: LOGIN сжигает токен после ~30–50 логинов подряд, поэтому
/// клиент авторизуется один раз и переиспользует соединение.
public actor MaxAuthService {
    public struct PhoneVerification: Sendable, Equatable {
        public var token: String
        public var codeLength: Int
        public var requestMaxDuration: TimeInterval
        public var requestCountLeft: Int
    }

    private let transport: MaxTransporting
    private let store: MaxCredentialStore
    private let userAgent: MaxRequests.UserAgent

    private var initialized = false

    public init(transport: MaxTransporting,
                store: MaxCredentialStore,
                userAgent: MaxRequests.UserAgent = .init()) {
        self.transport = transport
        self.store = store
        self.userAgent = userAgent
    }

    // MARK: INIT

    public func initialize() async throws {
        guard !initialized else { return }
        let frame = MaxFrame(command: 0,
                             sequence: transport.nextSeq(),
                             opcode: MaxOpcode.initSession.rawValue,
                             payload: MaxRequests.initSession(deviceID: store.deviceID, userAgent: userAgent))
        _ = try await transport.request(frame, timeout: MaxProtocol.requestTimeout)
        initialized = true
    }

    // MARK: SMS

    /// Отправляет SMS с кодом. `type` — "START_AUTH" или "RESEND".
    public func requestCode(phone: String, isResend: Bool = false, captchaToken: String? = nil) async throws -> PhoneVerification {
        try await initialize()
        let frame = MaxFrame(command: 0,
                             sequence: transport.nextSeq(),
                             opcode: MaxOpcode.verificationRequest.rawValue,
                             payload: MaxRequests.requestCode(phone: phone,
                                                              type: isResend ? "RESEND" : "START_AUTH",
                                                              captchaToken: captchaToken))
        do {
            let response = try await transport.request(frame, timeout: MaxProtocol.requestTimeout)
            let payload = response.payload
            guard let token = payload["token"]?.string else {
                throw MaxAuthError.unexpected("Сервер не вернул токен подтверждения")
            }
            return PhoneVerification(
                token: token,
                codeLength: Int(payload["codeLength"]?.int64 ?? 6),
                requestMaxDuration: Double(payload["requestMaxDuration"]?.int64 ?? 60_000) / 1000,
                requestCountLeft: Int(payload["requestCountLeft"]?.int64 ?? 0)
            )
        } catch MaxTransportError.server(_, let code, let message) {
            if code == "auth.captcha.required" || (message?.contains("captcha") ?? false) {
                throw MaxAuthError.captchaRequired
            }
            throw MaxAuthError.wrongCode(message ?? code ?? "неизвестная ошибка")
        }
    }

    /// Проверяет код из SMS и возвращает access token.
    @discardableResult
    public func confirmCode(token: String, code: String) async throws -> String {
        try await initialize()
        let frame = MaxFrame(command: 0,
                             sequence: transport.nextSeq(),
                             opcode: MaxOpcode.codeEnter.rawValue,
                             payload: MaxRequests.enterCode(token: token, code: code))
        let response: MaxFrame
        do {
            response = try await transport.request(frame, timeout: MaxProtocol.requestTimeout)
        } catch MaxTransportError.server(_, let code, let message) {
            switch code {
            case "auth.invalid.code": throw MaxAuthError.wrongCode("Неверный код")
            case "auth.blocked": throw MaxAuthError.blocked
            default: throw MaxAuthError.wrongCode(message ?? code ?? "неизвестная ошибка")
            }
        }

        // 2FA: сервер просит пароль отдельным шагом (opcode 115).
        let loginToken = response.payload["tokenAttrs"]?["LOGIN"]?["token"]?.string
        if loginToken == nil,
           response.payload["twoFactor"] != nil || response.payload["requirePassword"]?.bool == true {
            throw MaxAuthError.twoFactorRequired
        }
        guard let accessToken = loginToken else {
            throw MaxAuthError.unexpected("Нет токена в ответе")
        }
        store.accessToken = accessToken
        return accessToken
    }

    // MARK: LOGIN

    public struct LoginResult: Sendable {
        public var profile: MaxUser
        public var chats: [MaxChat]
        public var users: [MaxUser]
    }

    public func login(token: String? = nil) async throws -> LoginResult {
        try await initialize()
        guard let sessionToken = token ?? store.accessToken else {
            throw MaxAuthError.notAuthorized
        }

        let frame = MaxFrame(command: 0,
                             sequence: transport.nextSeq(),
                             opcode: MaxOpcode.login.rawValue,
                             payload: MaxRequests.login(token: sessionToken))
        let response: MaxFrame
        do {
            response = try await transport.request(frame, timeout: MaxProtocol.requestTimeout)
        } catch MaxTransportError.server(_, let code, let message) {
            if code == "auth.session.expired" || code == "auth.token.invalid" {
                throw MaxAuthError.sessionExpired
            }
            throw MaxAuthError.unexpected(message ?? code ?? "ошибка входа")
        }

        let payload = response.payload
        let profileValue = payload["profile"]?["contact"] ?? payload["profile"]
        guard let profile = profileValue.flatMap({ MaxParser.user(from: $0) }) else {
            throw MaxAuthError.unexpected("Не удалось разобрать профиль")
        }
        store.currentUserID = profile.id
        store.accessToken = sessionToken

        return LoginResult(profile: profile,
                           chats: MaxParser.chats(from: payload),
                           users: MaxParser.users(from: payload))
    }

    public func logout() {
        store.clearSession()
        transport.disconnect()
    }
}

public enum MaxAuthError: LocalizedError, Equatable {
    case notAuthorized
    case sessionExpired
    case captchaRequired
    case wrongCode(String)
    case blocked
    case twoFactorRequired
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Нужно войти в аккаунт"
        case .sessionExpired: return "Сессия истекла — войдите заново"
        case .captchaRequired: return "Слишком много попыток. Подтвердите, что вы не робот, на сайте VK"
        case .wrongCode(let message): return message
        case .blocked: return "Аккаунт заблокирован. Восстановление — в официальном клиенте"
        case .twoFactorRequired: return "Аккаунт защищён паролем (2FA). Этот сценарий мы добавим следующим шагом"
        case .unexpected(let message): return message
        }
    }
}
