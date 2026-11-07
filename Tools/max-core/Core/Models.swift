import Foundation

/// Модели домена. Все они — Sendable value types, чтобы свободно ходить
/// между сетевым слоем (actor) и главным потоком UI.
///
/// ID в MAX бывают огромными (64 бит: `9000000000003`, `116762203424780659`)
/// и приходят то числом, то строкой. Поэтому внутри клиента всё это `Int64`,
/// а при сравнении — через строковое представление.

public typealias MaxUserID = Int64
public typealias MaxChatID = Int64
public typealias MaxMessageID = String
public typealias UnixMillis = Int64

public struct MaxUser: Equatable, Sendable, Identifiable {
    public var id: MaxUserID
    public var firstName: String?
    public var lastName: String?
    public var fullName: String
    public var phoneNumber: String?
    public var about: String?
    public var avatarURL: URL?
    public var isBot: Bool

    public init(id: MaxUserID,
                firstName: String? = nil,
                lastName: String? = nil,
                fullName: String = "",
                phoneNumber: String? = nil,
                about: String? = nil,
                avatarURL: URL? = nil,
                isBot: Bool = false) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.fullName = fullName
        self.phoneNumber = phoneNumber
        self.about = about
        self.avatarURL = avatarURL
        self.isBot = isBot
    }

    /// Инициалы для плейсхолдера аватара.
    public var initials: String {
        let parts = fullName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

public enum MaxChatType: String, Sendable, CaseIterable {
    case dialog = "DIALOG"
    case chat = "CHAT"
    case channel = "CHANNEL"
    case unknown = "UNKNOWN"

    public init(raw: String?) {
        self = MaxChatType(rawValue: raw ?? "") ?? .unknown
    }
}

public enum MaxChatStatus: String, Sendable {
    case active = "ACTIVE"
    case archived = "ARCHIVED"
    case removed = "REMOVED"

    public var isVisible: Bool { self != .removed }
}

public struct MaxChat: Equatable, Sendable, Identifiable {
    public var id: MaxChatID
    public var type: MaxChatType
    public var title: String
    public var avatarURL: URL?
    public var status: MaxChatStatus
    /// `[userId: timestamp последнего прочтения]`
    public var participants: [MaxUserID: UnixMillis]
    public var lastMessage: MaxMessage?
    public var lastEventTime: UnixMillis
    public var unreadCount: Int
    public var ownerID: MaxUserID
    public var admins: [MaxUserID]
    public var participantsCount: Int
    public var isMuted: Bool
    public var description: String?
    public var isPinned: Bool

    public init(id: MaxChatID,
                type: MaxChatType,
                title: String,
                avatarURL: URL? = nil,
                status: MaxChatStatus = .active,
                participants: [MaxUserID: UnixMillis] = [:],
                lastMessage: MaxMessage? = nil,
                lastEventTime: UnixMillis = 0,
                unreadCount: Int = 0,
                ownerID: MaxUserID = 0,
                admins: [MaxUserID] = [],
                participantsCount: Int = 0,
                isMuted: Bool = false,
                description: String? = nil,
                isPinned: Bool = false) {
        self.id = id
        self.type = type
        self.title = title
        self.avatarURL = avatarURL
        self.status = status
        self.participants = participants
        self.lastMessage = lastMessage
        self.lastEventTime = lastEventTime
        self.unreadCount = unreadCount
        self.ownerID = ownerID
        self.admins = admins
        self.participantsCount = participantsCount
        self.isMuted = isMuted
        self.description = description
        self.isPinned = isPinned
    }

    /// Собеседник в личном диалоге (не включая себя).
    public func peer(in userID: MaxUserID?) -> MaxUserID? {
        guard type == .dialog else { return nil }
        return participants.keys.first { $0 != userID }
    }
}

public struct MaxMessage: Equatable, Sendable, Identifiable {
    public var id: MaxMessageID
    public var chatID: MaxChatID
    public var senderID: MaxUserID?
    public var text: String
    public var timestamp: UnixMillis
    public var elements: [MaxMessageElement]
    public var attachments: [MaxAttachment]
    public var reactions: MaxReactionInfo?
    public var cid: Int64?
    public var status: MaxMessageStatus
    public var isReadByMe: Bool

    public init(id: MaxMessageID,
                chatID: MaxChatID,
                senderID: MaxUserID?,
                text: String,
                timestamp: UnixMillis,
                elements: [MaxMessageElement] = [],
                attachments: [MaxAttachment] = [],
                reactions: MaxReactionInfo? = nil,
                cid: Int64? = nil,
                status: MaxMessageStatus = .sent,
                isReadByMe: Bool = false) {
        self.id = id
        self.chatID = chatID
        self.senderID = senderID
        self.text = text
        self.timestamp = timestamp
        self.elements = elements
        self.attachments = attachments
        self.reactions = reactions
        self.cid = cid
        self.status = status
        self.isReadByMe = isReadByMe
    }

    public var isOutgoing: Bool { status == .sending || status == .failed }
}

public enum MaxMessageStatus: String, Sendable {
    case sending
    case sent
    case edited
    case failed
}

/// Разметка внутри текста сообщения (elements[]).
public struct MaxMessageElement: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case link = "LINK"
        case strong = "STRONG"
        case emphasized = "EMPHASIZED"
        case underline = "UNDERLINE"
        case unknown = "UNKNOWN"
    }

    public var kind: Kind
    public var range: Range<Int> // в символах (String.Index-совместимо через utf16 offset)
    public var url: URL?

    public init(kind: Kind, from: Int, length: Int, url: URL? = nil) {
        self.kind = kind
        self.range = from..<(from + max(0, length))
        self.url = url
    }
}

/// Плоское представление вложения. Протокол возвращает `_type`-полиморфизм,
/// поэтому храним общий набор полей, а специфику — в `extra`.
public struct MaxAttachment: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case photo = "PHOTO"
        case video = "VIDEO"
        case file = "FILE"
        case audio = "AUDIO"
        case sticker = "STICKER"
        case share = "SHARE"
        case location = "LOCATION"
        case call = "CALL"
        case control = "CONTROL"
        case keyboard = "KEYBOARD"
        case unsupported = "UNSUPPORTED"
        case unknown = "UNKNOWN"
    }

    public var id: String
    public var kind: Kind
    public var url: URL?
    public var thumbnailURL: URL?
    public var fileName: String?
    public var fileSize: Int64?
    public var width: Int?
    public var height: Int?
    public var durationMillis: Int?
    public var title: String?
    public var subtitle: String?
    /// Сырые данные для того, что не помечено в модель.
    public var raw: [String: String]

    public init(id: String = UUID().uuidString,
                kind: Kind,
                url: URL? = nil,
                thumbnailURL: URL? = nil,
                fileName: String? = nil,
                fileSize: Int64? = nil,
                width: Int? = nil,
                height: Int? = nil,
                durationMillis: Int? = nil,
                title: String? = nil,
                subtitle: String? = nil,
                raw: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.durationMillis = durationMillis
        self.title = title
        self.subtitle = subtitle
        self.raw = raw
    }
}

public struct MaxReactionInfo: Equatable, Sendable {
    public struct Counter: Equatable, Sendable, Identifiable {
        public var reaction: String
        public var count: Int
        public var id: String { reaction }
    }

    public var counters: [Counter]
    public var yourReaction: String?
    public var totalCount: Int

    public init(counters: [Counter] = [], yourReaction: String? = nil, totalCount: Int = 0) {
        self.counters = counters
        self.yourReaction = yourReaction
        self.totalCount = totalCount
    }
}
