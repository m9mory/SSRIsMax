import Foundation

/// Константы протокола MAX (api.oneme.ru).
///
/// Протокол неофициальный: это закрытый API мобильного клиента MAX от VK.
/// Значения подобраны по публичным исследованиям трафика
/// (`github.com/pr0bel1230/max-api-docs`) и по поведению разных клиентов.
/// Сервер может потребовать поднять `appVersion` после крупного релиза.
public enum MaxProtocol {
    // Транспорт
    public static let wsURL = "wss://ws-api.oneme.ru/websocket"
    public static let tcpHost = "api.oneme.ru"
    public static let tcpPort = 443

    /// JSON-эндпоинт (web.max.ru), версия 11.
    public static let jsonVersion = 11
    /// MessagePack-эндпоинт TCP, версия 10.
    public static let binaryVersion = 10

    /// Версия приложения, которую мы представляем серверу.
    public static let appVersion = "26.11.0"

    /// Сервер закрывает неактивное соединение за ~30–60 с.
    public static let pingInterval: TimeInterval = 20
    public static let requestTimeout: TimeInterval = 20
    public static let maxReconnectAttempts = 6

    /// Сколько чатов запрашиваем при логине.
    public static let loginChatsCount = 100
}

/// Коды операций MAX. Помечаем только те, что реально используются
/// в клиенте; остальные пусть остаются числами в коде вызова.
public enum MaxOpcode: Int32 {
    // Системные
    case ping = 1
    case initSession = 6
    case verificationRequest = 17
    case codeEnter = 18
    case login = 19
    case profile = 16
    case captchaRequest = 224
    case config = 101
    case serverTime = 200
    case qrAuthRequest = 288
    case qrAuthPoll = 289
    case getBanners = 302
    case twoFactorPassword = 115

    // Контакты
    case getContacts = 32
    case contactsPresence = 35
    case contactByPhone = 46
    case getBlocked = 36
    case getUserInfo = 177
    case getCommonChats = 198
    case getSessions = 96

    // Чаты
    case getChats = 53
    case getChatsBulk = 48
    case getChatInfo = 61
    case chatRead = 50
    case chatActivity = 92
    case chatAction = 72
    case chatOperation = 77
    case chatSubscribe = 75
    case chatShow = 86
    case getFolders = 272
    case chatStats = 74

    // Сообщения
    case getHistory = 49
    case getMedia = 51
    case msgSend = 64
    case msgTyping = 65
    case msgDelete = 66
    case msgEdit = 67
    case forwardMessage = 70
    case getMessage = 71
    case searchMessages = 73
    case searchGlobal = 60
    case reactSet = 178
    case reactRemove = 179
    case getReactions = 181
    case getReactionsBulk = 180

    // Файлы
    case imageUploadURL = 80
    case imageUploadIUSmile = 81
    case videoUploadURL = 82
    case fileUpload = 87
    case fileDownload = 88

    // Пуш-уведомления (cmd = 0)
    case notifMsgEdit = 128
    case notifTyping = 129
    case notifRead = 130
    case notifPresence = 132
    case notifAttach = 136
    case notifIncomingCall = 137
    case notifMsgDeleteRange = 140
    case notifMsgDelete = 142
    case notifReaction = 156
}

/// Кадр протокола MAX — одинаково выглядит в JSON и в MessagePack.
public struct MaxFrame: Equatable, Sendable {
    public var version: Int
    public var command: Int
    public var sequence: Int
    public var opcode: Int32
    public var payload: MPValue

    public init(version: Int = MaxProtocol.jsonVersion,
                command: Int,
                sequence: Int,
                opcode: Int32,
                payload: MPValue = .map([:])) {
        self.version = version
        self.command = command
        self.sequence = sequence
        self.opcode = opcode
        self.payload = payload
    }

    public enum Command: Int {
        case request = 0
        case response = 1
        case error = 3
    }

    // MARK: JSON

    public init(jsonData: Data) throws {
        guard let any = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MaxFrameError.invalidFrame("not a JSON object")
        }
        self.version = (any["ver"] as? NSNumber)?.intValue ?? MaxProtocol.jsonVersion
        self.command = (any["cmd"] as? NSNumber)?.intValue ?? 0
        self.sequence = (any["seq"] as? NSNumber)?.intValue ?? 0
        self.opcode = Int32((any["opcode"] as? NSNumber)?.intValue ?? 0)
        self.payload = MPValue(jsonObject: any["payload"] ?? [:])
    }

    public func jsonData() throws -> Data {
        let dict: [String: Any] = [
            "ver": version,
            "cmd": command,
            "seq": sequence,
            "opcode": Int(opcode),
            "payload": payload.foundation
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    // MARK: MessagePack

    /// Бинарный фрейм: массив `[ver, cmd, seq, opcode, payload]`.
    public init(binaryData: Data) throws {
        let values = try MPDecoder.decodeAll(binaryData)
        guard values.count >= 5 else {
            throw MaxFrameError.invalidFrame("binary frame expects 5 values, got \(values.count)")
        }
        self.version = Int(values[0].int64 ?? 0)
        self.command = Int(values[1].int64 ?? 0)
        self.sequence = Int(values[2].int64 ?? 0)
        self.opcode = Int32(values[3].int64 ?? 0)
        self.payload = values[4]
    }

    public func binaryData() -> Data {
        MPEncoder.encode(.array([
            .int(Int64(version)),
            .int(Int64(command)),
            .int(Int64(sequence)),
            .int(Int64(opcode)),
            payload
        ]))
    }
}

public enum MaxFrameError: Error, CustomStringConvertible {
    case invalidFrame(String)

    public var description: String {
        switch self {
        case .invalidFrame(let message):
            return "Invalid MAX frame: \(message)"
        }
    }
}
