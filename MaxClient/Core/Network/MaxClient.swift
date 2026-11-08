import Foundation

/// Высокоуровневый клиент MAX поверх транспорта.
///
/// Отвечает за:
/// - одну постоянную сессию (INIT → LOGIN) и переподключение;
/// - seq-матчинг запросов;
/// - доставку обновлений в поток `updates`.
public actor MaxClient {
    public enum Update: Sendable {
        case newMessage(MaxMessage)
        case messageEdited(MaxMessage)
        case messageDeleted(chatID: MaxChatID, messageIDs: [MaxMessageID])
        case typing(userID: MaxUserID, chatID: MaxChatID)
        case read(userID: MaxUserID, chatID: MaxChatID, mark: UnixMillis)
        case presence(userID: MaxUserID, isOnline: Bool, seen: UnixMillis)
        case reaction(chatID: MaxChatID, messageID: MaxMessageID, info: MaxReactionInfo)
        case attachmentReady
        case incomingCall(chatID: MaxChatID?, from: MaxUserID?)
        case connectionState(ConnectionState)
    }

    public enum ConnectionState: String, Sendable {
        case idle
        case connecting
        case online
        case offline
    }

    private let transport: MaxTransporting
    private let store: MaxCredentialStore
    private let userAgent: MaxRequests.UserAgent

    private var state: ConnectionState = .idle
    private var updateContinuations: [UUID: AsyncStream<Update>.Continuation] = [:]
    private var subscribedChats = Set<MaxChatID>()
    private var currentUserID: MaxUserID?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(transport: MaxTransporting,
                store: MaxCredentialStore,
                userAgent: MaxRequests.UserAgent = .init()) {
        self.transport = transport
        self.store = store
        self.userAgent = userAgent
    }

    // MARK: - Обновления

    public func updates() -> AsyncStream<Update> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            continuation.yield(.connectionState(state))
        }
    }

    private func removeContinuation(_ id: UUID) {
        updateContinuations[id] = nil
    }

    private func yield(_ update: Update) {
        for continuation in updateContinuations.values {
            continuation.yield(update)
        }
    }

    private func setState(_ newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        yield(.connectionState(newState))
    }

    public func currentState() -> ConnectionState { state }

    // MARK: - Соединение

    public func connect(token: String? = nil, userID: MaxUserID? = nil) async throws -> (
        profile: MaxUser, chats: [MaxChat], users: [MaxUser]
    ) {
        bindTransportEvents()
        guard state != .online else {
            // Уже подключены. Повторный LOGIN не нужен: он «сжигает»
            // токен и рискует нарваться на лимит логинов, поэтому
            // профиль берётся из памяти/кеша, а чаты — через GET_CHATS.
            let knownID = currentUserID ?? store.currentUserID ?? userID
            let cached = (try? store.cachedProfile()) ?? knownID.map { MaxUser(id: $0) }
            guard let profile = cached else { throw MaxTransportError.notConnected }
            let chats = (try? await loadChats().chats) ?? []
            return (profile, chats, [])
        }

        setState(.connecting)
        do {
            // ensureConnected, а не connect: при входе по SMS соединение
            // уже открыто и сессия инициализирована через INIT в
            // MaxAuthService. Повторный connect сбросил бы счётчик seq и
            // пересоздал сокет прямо перед LOGIN.
            try await transport.ensureConnected()
        } catch {
            setState(.offline)
            throw error
        }

        let auth = MaxAuthService(transport: transport, store: store, userAgent: userAgent)
        do {
            let result = try await auth.login(token: token)
            currentUserID = result.profile.id
            store.currentUserID = result.profile.id
            store.cacheProfile(result.profile)
            setState(.online)
            startPing()
            return (result.profile, result.chats, result.users)
        } catch {
            setState(.offline)
            throw error
        }
    }

    public func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        transport.disconnect()
        setState(.offline)
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MaxProtocol.pingInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.sendPing()
            }
        }
    }

    private func sendPing() async {
        do {
            let frame = MaxFrame(command: 0,
                                 sequence: transport.nextSeq(),
                                 opcode: MaxOpcode.ping.rawValue,
                                 payload: MPValue(["interactive": .bool(true)]))
            try await transport.send(frame: frame)
        } catch {
            setState(.offline)
        }
    }

    // MARK: - Универсальный запрос

    private func perform(_ opcode: MaxOpcode, payload: MPValue, timeout: TimeInterval = MaxProtocol.requestTimeout) async throws -> MPValue {
        // seq берётся у транспорта, а не у своей переменной: ответы
        // разбираются по seq внутри транспорта, и второй независимый
        // счётчик с тем же началом гарантированно давал бы коллизии с
        // запросами авторизации.
        let frame = MaxFrame(command: 0, sequence: transport.nextSeq(), opcode: opcode.rawValue, payload: payload)
        let response = try await transport.request(frame, timeout: timeout)
        return response.payload
    }

    // MARK: - Чаты

    public func loadChats(limit: Int = 100, marker: UnixMillis? = nil) async throws -> (chats: [MaxChat], nextMarker: UnixMillis) {
        let payload = try await perform(.getChats,
                                        payload: MaxRequests.chats(count: limit,
                                                                   marker: marker ?? Int64(Date().timeIntervalSince1970 * 1000)))
        let chats = MaxParser.chats(from: payload)
        let next = payload["marker"]?.int64 ?? 0
        return (chats, next)
    }

    public func chatInfo(_ chatID: MaxChatID) async throws -> MaxChat? {
        let payload = try await perform(.getChatInfo, payload: MaxRequests.chatInfo(chatID: chatID))
        guard let chat = payload["chat"] else { return nil }
        return MaxParser.chat(from: chat)
    }

    public func subscribe(to chatIDs: [MaxChatID]) async {
        for chatID in chatIDs where !subscribedChats.contains(chatID) {
            subscribedChats.insert(chatID)
            _ = try? await perform(.chatSubscribe, payload: MaxRequests.subscribe(chatID: chatID))
        }
    }

    public func unsubscribe(from chatID: MaxChatID) async {
        subscribedChats.remove(chatID)
        _ = try? await perform(.chatSubscribe, payload: MaxRequests.subscribe(chatID: chatID, subscribe: false))
    }

    // MARK: - Сообщения

    public func history(chatID: MaxChatID, limit: Int = 50, before: UnixMillis? = nil) async throws -> [MaxMessage] {
        let from = before ?? Int64(Date().timeIntervalSince1970 * 1000)
        let payload = try await perform(.getHistory,
                                        payload: MaxRequests.history(chatID: chatID, backward: limit, from: from),
                                        timeout: 30)
        let messages = MaxParser.messages(from: payload, chatID: chatID)
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    public func send(chatID: MaxChatID, text: String) async throws -> MaxMessage {
        let cid = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = try await perform(.msgSend,
                                        payload: MaxRequests.sendMessage(chatID: chatID, text: text, cid: cid))
        guard let message = MaxParser.message(from: payload["message"] ?? payload, chatID: chatID) else {
            throw MaxTransportError.decode("MSG_SEND: нет сообщения в ответе")
        }
        return message
    }

    public func edit(chatID: MaxChatID, messageID: MaxMessageID, text: String) async throws {
        _ = try await perform(.msgEdit, payload: MaxRequests.edit(chatID: chatID, messageID: messageID, text: text))
    }

    public func delete(chatID: MaxChatID, messageID: MaxMessageID, forMe: Bool = true) async throws {
        _ = try await perform(.msgDelete, payload: MaxRequests.delete(chatID: chatID, messageID: messageID, forMe: forMe))
    }

    public func sendTyping(chatID: MaxChatID) {
        Task { _ = try? await perform(.msgTyping, payload: MaxRequests.typing(chatID: chatID)) }
    }

    public func markRead(chatID: MaxChatID, messageID: MaxMessageID, mark: UnixMillis) {
        Task { _ = try? await perform(.chatRead, payload: MaxRequests.markRead(chatID: chatID, messageID: messageID, mark: mark)) }
    }

    public func react(chatID: MaxChatID, messageID: MaxMessageID, emoji: String) async throws -> MaxReactionInfo? {
        let payload = try await perform(.reactSet,
                                        payload: MaxRequests.react(chatID: chatID, messageID: messageID, emoji: emoji))
        return MaxParser.reactions(from: payload["reactionInfo"])
    }

    public func unreact(chatID: MaxChatID, messageID: MaxMessageID) async throws {
        _ = try await perform(.reactRemove, payload: MaxRequests.unreact(chatID: chatID, messageID: messageID))
    }

    // MARK: - Контакты

    public func contact(ids: [MaxUserID]) async throws -> [MaxUser] {
        let payload = try await perform(.getContacts,
                                        payload: MPValue(["contactIds": .array(ids.map { .int($0) })]))
        return MaxParser.users(from: payload)
    }

    public func contactByPhone(_ phone: String) async throws -> MaxUser? {
        let payload = try await perform(.contactByPhone, payload: MaxRequests.contactByPhone(phone))
        return MaxParser.user(from: payload["contact"] ?? payload)
    }

    // MARK: - Соединение: события и переподключение

    public func bindTransportEvents() {
        // Замыкания транспорта вызываются вне актора — только hop обратно.
        let onEvent = transport.onEvent
        transport.onEvent = { [weak self] event in
            onEvent?(event)
            Task { await self?.handleEvent(event) }
        }
        let onDisconnect = transport.onDisconnect
        transport.onDisconnect = { [weak self] error in
            onDisconnect?(error)
            Task { await self?.handleDisconnect(error) }
        }
    }

    private func handleEvent(_ event: MaxClientEvent) {
        switch event {
        case .newMessage(let message, _):
            // chatID уже лежит в самом объекте сообщения.
            yield(.newMessage(message))
        case .messageEdited(let message, _):
            yield(.messageEdited(message))
        case .messageDeleted(let chatID, let ids):
            yield(.messageDeleted(chatID: chatID, messageIDs: ids))
        case .typing(let userID, let chatID):
            yield(.typing(userID: userID, chatID: chatID))
        case .read(let userID, let chatID, let mark):
            yield(.read(userID: userID, chatID: chatID, mark: mark))
        case .presence(let userID, let isOnline, let seen):
            yield(.presence(userID: userID, isOnline: isOnline, seen: seen))
        case .reaction(let chatID, let messageID, let info):
            yield(.reaction(chatID: chatID, messageID: messageID, info: info))
        case .attachReady:
            yield(.attachmentReady)
        case .incomingCall(let chatID, let from):
            yield(.incomingCall(chatID: chatID, from: from))
        case .ping, .unknown:
            break
        }
    }

    private func handleDisconnect(_ error: Error?) async {
        setState(.offline)
        guard let token = store.accessToken, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(token: token)
        }
    }

    private func reconnectLoop(token: String) async {
        defer { reconnectTask = nil }
        var delay: UInt64 = 1
        for attempt in 0..<MaxProtocol.maxReconnectAttempts {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            do {
                _ = try await connect(token: token)
                for chatID in subscribedChats {
                    _ = try? await perform(.chatSubscribe, payload: MaxRequests.subscribe(chatID: chatID))
                }
                return
            } catch MaxTransportError.unauthorized {
                return
            } catch {
                delay = min(delay * 2, 30)
                if attempt == MaxProtocol.maxReconnectAttempts - 1 {
                    setState(.offline)
                }
            }
        }
    }
}
