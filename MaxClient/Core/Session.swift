import Foundation
import Combine
import GRDB

/// Сессия приложения: одна точка правды для UI.
///
/// Соединяет `MaxClient` (сеть), репозитории (SQLite) и Keychain.
/// UI подписывается на `@Published` и ничего не знает про протокол.
@MainActor
public final class Session: ObservableObject {
    public enum Phase: Equatable {
        case launching
        case unauthenticated
        case authenticated
    }

    public struct AuthFlowState: Equatable {
        public var phone: String = ""
        public var pendingToken: String?
        public var codeLength: Int = 6
        public var resendAvailableIn: Int = 0
        public var isLoading = false
        public var errorMessage: String?
    }

    @Published public private(set) var phase: Phase = .launching
    @Published public private(set) var chats: [MaxChat] = []
    @Published public private(set) var profile: MaxUser?
    @Published public private(set) var connectionState: MaxClient.ConnectionState = .idle
    @Published public var auth = AuthFlowState()
    @Published public private(set) var activeChatID: MaxChatID?
    @Published public private(set) var typingUserIDs: [MaxChatID: MaxUserID] = [:]

    public let settings: SettingsStore

    private let store: MaxCredentialStore
    private let client: MaxClient
    private let transport: MaxTransporting
    private let authService: MaxAuthService
    private let chatRepository: ChatRepository
    private let messageRepository: MessageRepository
    private let userRepository: UserRepository

    private var updateTask: Task<Void, Never>?
    private var typingClearTasks: [MaxChatID: Task<Void, Never>] = [:]
    private var resendTask: Task<Void, Never>?

    public init(store: MaxCredentialStore, settings: SettingsStore, db: DatabaseQueue) {
        self.store = store
        self.settings = settings
        self.chatRepository = ChatRepository(queue: db)
        self.messageRepository = MessageRepository(queue: db)
        self.userRepository = UserRepository(queue: db)

        let transport: MaxTransporting = settings.settings.transport == .tcp
            ? MaxTCPTransport()
            : MaxWebSocketTransport()
        self.transport = transport
        self.client = MaxClient(transport: transport, store: store)
        self.authService = MaxAuthService(transport: transport, store: store)
    }

    // MARK: - Жизненный цикл

    public func bootstrap() async {
        await client.bindTransportEvents()

        guard let token = store.accessToken else {
            phase = .unauthenticated
            return
        }

        do {
            let result = try await client.connect(token: token)
            try userRepository.save(users: result.users + [result.profile])
            try chatRepository.save(chats: result.chats)
            await refreshChats()
            profile = result.profile
            startUpdates()
            await client.subscribe(to: result.chats.map(\.id))
            phase = .authenticated
        } catch MaxTransportError.unauthorized {
            store.clearSession()
            phase = .unauthenticated
        } catch MaxAuthError.sessionExpired {
            store.clearSession()
            phase = .unauthenticated
        } catch {
            await refreshChats()
            if chats.isEmpty {
                auth.errorMessage = "Нет связи с сервером. Проверьте интернет и попробуйте снова."
                phase = .unauthenticated
            } else {
                // Показываем кеш в офлайне, фоновая реконнект-логика поднимет сеть.
                phase = .authenticated
                connectionState = .offline
            }
        }
    }

    private func startUpdates() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in await self.client.updates() {
                await self.handle(update)
            }
        }
    }

    // MARK: - Вход по SMS

    public func normalizePhone(_ raw: String) -> String {
        PhoneFormatter.normalize(raw) ?? "+" + raw.filter(\.isNumber)
    }

    /// Отправляет SMS с кодом.
    ///
    /// `phone` передаётся из поля ввода явно: экран держит своё
    /// состояние, а `auth.phone` — это уже нормализованный номер для
    /// показа («Код отправлен на …»). Раньше здесь читался `auth.phone`,
    /// который до первого успешного запроса пуст, поэтому кнопка всегда
    /// упиралась в проверку формата.
    public func requestCode(phone rawPhone: String? = nil, isResend: Bool = false) async {
        auth.errorMessage = nil

        let source = rawPhone ?? auth.phone
        guard let phone = PhoneFormatter.normalize(source) else {
            auth.errorMessage = "Введите номер в формате +7 999 123-45-67"
            return
        }

        auth.isLoading = true
        defer { auth.isLoading = false }
        auth.phone = phone

        do {
            let verification = try await authService.requestCode(phone: phone, isResend: isResend)
            auth.pendingToken = verification.token
            auth.codeLength = verification.codeLength
            startResendTimer(seconds: Int(verification.requestMaxDuration))
        } catch MaxAuthError.captchaRequired {
            auth.errorMessage = "Слишком много попыток. Подтвердите, что вы не робот, в браузере, потом вернитесь сюда."
        } catch {
            auth.errorMessage = error.localizedDescription
        }
    }

    /// «Назад» на экране кода: прекращает ввод, номер остаётся в поле.
    public func cancelCodeEntry() {
        resendTask?.cancel()
        resendTask = nil
        let phone = auth.phone
        auth = AuthFlowState()
        auth.phone = phone
    }

    private func startResendTimer(seconds: Int) {
        resendTask?.cancel()
        auth.resendAvailableIn = max(seconds, 30)
        resendTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.auth.resendAvailableIn > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.auth.resendAvailableIn -= 1
            }
        }
    }

    public func confirmCode(_ code: String) async {
        guard let token = auth.pendingToken else { return }
        auth.errorMessage = nil
        auth.isLoading = true
        defer { auth.isLoading = false }

        do {
            let accessToken = try await authService.confirmCode(token: token, code: code)
            let result = try await client.connect(token: accessToken)
            try userRepository.save(users: result.users + [result.profile])
            try chatRepository.save(chats: result.chats)
            await refreshChats()
            profile = result.profile
            startUpdates()
            await client.subscribe(to: result.chats.map(\.id))
            auth = AuthFlowState()
            phase = .authenticated
        } catch MaxAuthError.twoFactorRequired {
            auth.errorMessage = "На аккаунте включён пароль (2FA). Поддержку 2FA добавим следующим шагом."
        } catch {
            auth.errorMessage = error.localizedDescription
        }
    }

    public func logout() async {
        await client.disconnect()
        store.clearSession()
        try? messageRepository.deleteAll()
        try? chatRepository.deleteAll()
        try? userRepository.deleteAll()
        updateTask?.cancel()
        updateTask = nil
        typingClearTasks.values.forEach { $0.cancel() }
        typingClearTasks = [:]
        resendTask?.cancel()
        resendTask = nil
        chats = []
        profile = nil
        activeChatID = nil
        typingUserIDs = [:]
        connectionState = .idle
        auth = AuthFlowState()
        phase = .unauthenticated
    }

    // MARK: - Чаты

    public func refreshChats() async {
        do {
            chats = try chatRepository.chats().filter { $0.status.isVisible }
        } catch {
            print("refreshChats failed: \(error)")
        }
    }

    /// Ручное переподключение по кнопке «Повторить» в баннере офлайна.
    public func reconnect() async {
        guard let token = store.accessToken else {
            phase = .unauthenticated
            return
        }
        connectionState = .connecting
        do {
            let result = try await client.connect(token: token)
            try userRepository.save(users: result.users + [result.profile])
            try chatRepository.save(chats: result.chats)
            await refreshChats()
            profile = result.profile
            startUpdates()
            await client.subscribe(to: result.chats.map(\.id))
            phase = .authenticated
        } catch {
            // Ошибку не раздуваем: баннер офлайна останется на экране,
            // фоновая логика продолжит попытки.
            print("reconnect failed: \(error)")
        }
    }

    /// Чистит только локальную переписку: чаты и аккаунт остаются.
    public func clearLocalMessages() async {
        try? messageRepository.deleteAll()
        for chat in chats {
            try? chatRepository.resetUnread(chatID: chat.id)
        }
        await refreshChats()
    }

    public func pullChats() async {
        do {
            let (remote, _) = try await client.loadChats()
            try chatRepository.save(chats: remote)
            await refreshChats()
            await client.subscribe(to: remote.map(\.id))
        } catch {
            print("pullChats failed: \(error)")
        }
    }

    // MARK: - Переписка

    public func messages(chatID: MaxChatID) async -> [MaxMessage] {
        let stored = (try? messageRepository.messages(chatID: chatID)) ?? []
        // Кеш показываем сразу, историю подмешиваем только если он пуст:
        // иначе каждое открытие чата дёргало бы сеть.
        if !stored.isEmpty { return stored }
        do {
            let remote = try await client.history(chatID: chatID)
            try messageRepository.save(items: remote)
            let after = (try? messageRepository.messages(chatID: chatID)) ?? remote
            return after
        } catch {
            return stored
        }
    }

    public func loadOlder(chatID: MaxChatID, before timestamp: UnixMillis) async -> [MaxMessage] {
        do {
            let remote = try await client.history(chatID: chatID, before: timestamp)
            try messageRepository.save(items: remote)
            return try messageRepository.olderMessages(chatID: chatID, before: timestamp)
        } catch {
            return []
        }
    }

    public func openChat(_ chatID: MaxChatID) async {
        activeChatID = chatID
        await client.subscribe(to: [chatID])
        try? chatRepository.resetUnread(chatID: chatID)
        await refreshChats()
    }

    public func closeChat() {
        activeChatID = nil
    }

    public func send(text: String, to chatID: MaxChatID) async {
        let optimisticID = "local-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let optimistic = MaxMessage(id: optimisticID,
                                    chatID: chatID,
                                    senderID: profile?.id,
                                    text: text,
                                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                    status: .sending)
        do {
            try messageRepository.save(items: [optimistic])
            let sent = try await client.send(chatID: chatID, text: text)
            try? messageRepository.delete(id: optimisticID)
            try messageRepository.save(items: [MaxMessage(id: sent.id,
                                                          chatID: chatID,
                                                          senderID: profile?.id,
                                                          text: text,
                                                          timestamp: sent.timestamp,
                                                          cid: sent.cid,
                                                          status: .sent)])
            await refreshChats()
        } catch {
            try? messageRepository.markFailed(id: optimisticID)
        }
    }

    /// `client` — actor, поэтому вызов из @MainActor обязан быть async.
    /// Набор текста — fire-and-forget: UI не ждёт подтверждения.
    public func sendTyping(chatID: MaxChatID) {
        Task { await client.sendTyping(chatID: chatID) }
    }

    public func deleteMessage(_ message: MaxMessage, in chatID: MaxChatID) async {
        do {
            try await client.delete(chatID: chatID, messageID: message.id)
            try? messageRepository.delete(id: message.id)
            await refreshChats()
        } catch {
            print("delete failed: \(error)")
        }
    }

    /// Отметить весь чат прочитанным (свайп в списке).
    public func markChatRead(_ chatID: MaxChatID) async {
        let last = try? messageRepository.latest(chatID: chatID)
        try? chatRepository.resetUnread(chatID: chatID)
        if settings.settings.sendReadReceipts, let last {
            await client.markRead(chatID: chatID, messageID: last.id, mark: last.timestamp)
        }
        await refreshChats()
    }

    public func markRead(chatID: MaxChatID, message: MaxMessage) {
        guard settings.settings.sendReadReceipts else { return }
        try? chatRepository.resetUnread(chatID: chatID)
        let id = message.id
        let mark = message.timestamp
        Task { await client.markRead(chatID: chatID, messageID: id, mark: mark) }
    }

    public func react(chatID: MaxChatID, messageID: MaxMessageID, emoji: String) async {
        do {
            let info = try await client.react(chatID: chatID, messageID: messageID, emoji: emoji)
            if let info { try? messageRepository.setReactions(info, messageID: messageID) }
        } catch {
            print("react failed: \(error)")
        }
    }

    // MARK: - Обновления из сети

    private func handle(_ update: MaxClient.Update) async {
        switch update {
        case .connectionState(let state):
            connectionState = state
        case .newMessage(let message):
            try? messageRepository.save(items: [message])
            if message.chatID == activeChatID {
                try? chatRepository.resetUnread(chatID: message.chatID)
            } else if message.senderID != profile?.id {
                try? chatRepository.incrementUnread(chatID: message.chatID, timestamp: message.timestamp)
            }
            await refreshChats()
        case .messageEdited(let message):
            try? messageRepository.save(items: [message])
            await refreshChats()
        case .messageDeleted(_, let ids):
            try? messageRepository.delete(ids: ids)
        case .typing(let userID, let chatID) where userID != profile?.id:
            typingUserIDs[chatID] = userID
            typingClearTasks[chatID]?.cancel()
            typingClearTasks[chatID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.typingUserIDs[chatID] = nil
            }
        case .reaction(_, let messageID, let info):
            try? messageRepository.setReactions(info, messageID: messageID)
        case .read, .presence, .attachmentReady, .incomingCall, .typing:
            break
        }
    }
}
