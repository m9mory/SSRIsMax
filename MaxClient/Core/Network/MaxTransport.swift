import Foundation

#if os(Linux) || os(Windows)
import FoundationNetworking
#endif

/// Ошибки транспорта и протокола.
public enum MaxTransportError: LocalizedError, Equatable {
    case notConnected
    case connectionFailed(String)
    case timedOut(opcode: Int32)
    case server(opcode: Int32, code: String?, message: String?)
    case unauthorized
    case decode(String)
    case closed(String?)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Нет соединения с сервером MAX"
        case .connectionFailed(let reason):
            return "Не удалось подключиться: \(reason)"
        case .timedOut(let opcode):
            return "Сервер не ответил на запрос \(opcode)"
        case .server(let opcode, let code, let message):
            return "Ошибка \(opcode): \(code ?? "unknown") — \(message ?? "")"
        case .unauthorized:
            return "Сессия истекла, нужно войти заново"
        case .decode(let message):
            return "Ошибка разбора ответа: \(message)"
        case .closed(let reason):
            return "Соединение закрыто\(reason.map { ": \($0)" } ?? "")"
        }
    }
}

/// Абстракция над конкретным транспортом (JSON WebSocket / MessagePack TCP).
///
/// `MaxClient` работает только с этим протоколом, поэтому переключить
/// реализацию можно одной строкой.
public protocol MaxTransporting: AnyObject {
    /// Push-кадры и прочие события сервера.
    var onEvent: ((MaxClientEvent) -> Void)? { get set }
    /// Разрыв соединения.
    var onDisconnect: ((Error?) -> Void)? { get set }

    func connect() async throws
    func send(frame: MaxFrame) async throws
    /// Ждёт ответ с `sequence == frame.sequence`. Push автоматически
    /// уходят в `onEvent`.
    func request(_ frame: MaxFrame, timeout: TimeInterval) async throws -> MaxFrame
    func disconnect()
}

// MARK: - События сервера

public enum MaxClientEvent: Sendable, Equatable {
    case newMessage(MaxMessage, chatID: MaxChatID)
    case messageEdited(MaxMessage, chatID: MaxChatID)
    case messageDeleted(chatID: MaxChatID, messageIDs: [MaxMessageID])
    case typing(userID: MaxUserID, chatID: MaxChatID)
    case read(userID: MaxUserID, chatID: MaxChatID, mark: UnixMillis)
    case presence(userID: MaxUserID, isOnline: Bool, seen: UnixMillis)
    case reaction(chatID: MaxChatID, messageID: MaxMessageID, info: MaxReactionInfo)
    case attachReady // файл загружен, можно отправлять
    case incomingCall(chatID: MaxChatID?, from: MaxUserID?)
    case ping
    case unknown(Int32, MPValue)
}

// MARK: - Мультиплексирование запросов и ответов по seq

/// Общая логика для транспортов: pending-запросы, seq, таймауты.
public final class MaxFramePump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<MaxFrame, Error>] = [:]
    private var nextSequence = 0

    public init() {}

    public func nextSeq() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextSequence = nextSequence % 65535 + 1
        return nextSequence
    }

    public func registerAwaiting(_ seq: Int, continuation: CheckedContinuation<MaxFrame, Error>) {
        lock.lock()
        pending[seq] = continuation
        lock.unlock()
    }

    public func completing(_ seq: Int, frame: MaxFrame) {
        lock.lock()
        let continuation = pending.removeValue(forKey: seq)
        lock.unlock()
        continuation?.resume(returning: frame)
    }

    public func failing(_ seq: Int, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: seq)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    public func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in all {
            continuation.resume(throwing: error)
        }
    }

    public func reset() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    /// Таймаут на конкретный ожидающий запрос.
    public func failLater(seq: Int, after seconds: TimeInterval, error: Error) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.failing(seq, error: error)
        }
    }
}

// MARK: - Наблюдение за состоянием (для тестов)

public extension MaxFramePump {
    /// Сколько запросов сейчас ждут ответа.
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Ждёт, пока накопится `count` ожидающих запросов. Задача тестов:
    /// позволяет проверить мультиплексирование без гонок по времени.
    func waitUntilPending(_ count: Int, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

public enum MaxEventMapper {
    public static func map(frame: MaxFrame) -> MaxClientEvent {
        let payload = frame.payload
        let chatID = MaxParser.int64(payload["chatId"]) ?? 0

        switch frame.opcode {
        case MaxOpcode.ping.rawValue:
            return .ping
        case MaxOpcode.notifTyping.rawValue:
            return .typing(userID: MaxParser.int64(payload["userId"]) ?? 0, chatID: chatID)
        case MaxOpcode.notifRead.rawValue:
            return .read(userID: MaxParser.int64(payload["userId"]) ?? 0,
                         chatID: chatID,
                         mark: MaxParser.time(payload["mark"]))
        case MaxOpcode.notifPresence.rawValue:
            return .presence(userID: MaxParser.int64(payload["userId"]) ?? 0,
                             isOnline: (MaxParser.int64(payload["presence"]?["status"]) ?? 0) == 1,
                             seen: MaxParser.time(payload["presence"]?["seen"]))
        case MaxOpcode.notifMsgEdit.rawValue:
            if let message = MaxParser.message(from: payload["message"] ?? payload, chatID: chatID) {
                return .messageEdited(message, chatID: message.chatID)
            }
            return .unknown(frame.opcode, payload)
        case MaxOpcode.notifMsgDelete.rawValue, MaxOpcode.notifMsgDeleteRange.rawValue:
            let ids = (payload["messageIds"]?.arrayItems ?? []).compactMap { $0.string }
            return .messageDeleted(chatID: chatID, messageIDs: ids)
        case MaxOpcode.notifReaction.rawValue:
            return .reaction(chatID: chatID,
                             messageID: payload["messageId"]?.string ?? "",
                             info: MaxParser.reactions(from: payload["reactionInfo"]) ?? MaxReactionInfo())
        case MaxOpcode.notifAttach.rawValue:
            return .attachReady
        case MaxOpcode.notifIncomingCall.rawValue:
            return .incomingCall(chatID: chatID == 0 ? nil : chatID,
                                 from: MaxParser.int64(payload["userId"]))
        case MaxOpcode.msgSend.rawValue:
            // Входящие сообщения приходят push-ом с opcode 64.
            guard let message = MaxParser.message(from: payload["message"] ?? payload, chatID: chatID) else {
                return .unknown(frame.opcode, payload)
            }
            return .newMessage(message, chatID: message.chatID)
        default:
            return .unknown(frame.opcode, payload)
        }
    }
}
