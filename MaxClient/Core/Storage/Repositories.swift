import Foundation
import GRDB

// MARK: - Records

struct UserRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "user"

    var id: Int64
    var firstName: String?
    var lastName: String?
    var fullName: String
    var phoneNumber: String?
    var about: String?
    var avatarURL: String?
    var isBot: Bool

    init(_ user: MaxUser) {
        id = user.id
        firstName = user.firstName
        lastName = user.lastName
        fullName = user.fullName
        phoneNumber = user.phoneNumber
        about = user.about
        avatarURL = user.avatarURL?.absoluteString
        isBot = user.isBot
    }

    var domain: MaxUser {
        MaxUser(id: id,
                firstName: firstName,
                lastName: lastName,
                fullName: fullName,
                phoneNumber: phoneNumber,
                about: about,
                avatarURL: avatarURL.flatMap(URL.init(string:)),
                isBot: isBot)
    }
}

struct ChatRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "chat"

    var id: Int64
    var type: String
    var title: String
    var avatarURL: String?
    var status: String
    var lastEventTime: Int64
    var unreadCount: Int
    var ownerID: Int64
    var participantsCount: Int
    var isMuted: Bool
    var isPinned: Bool
    var descriptionText: String?
    var participantsJSON: String?
    var adminsJSON: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, avatarURL, status, lastEventTime, unreadCount, ownerID
        case participantsCount, isMuted, isPinned
        case descriptionText
        case participantsJSON, adminsJSON
    }

    init(_ chat: MaxChat) {
        id = chat.id
        type = chat.type.rawValue
        title = chat.title
        avatarURL = chat.avatarURL?.absoluteString
        status = chat.status.rawValue
        lastEventTime = chat.lastEventTime
        unreadCount = chat.unreadCount
        ownerID = chat.ownerID
        participantsCount = chat.participantsCount
        isMuted = chat.isMuted
        isPinned = chat.isPinned
        descriptionText = chat.description
        participantsJSON = JSONColumns.encode(chat.participants)
        adminsJSON = JSONColumns.encode(chat.admins)
    }

    var domain: MaxChat {
        MaxChat(id: id,
                type: MaxChatType(raw: type),
                title: title,
                avatarURL: avatarURL.flatMap(URL.init(string:)),
                status: MaxChatStatus(rawValue: status) ?? .active,
                participants: JSONColumns.decode(participantsJSON) ?? [:],
                lastMessage: nil,
                lastEventTime: lastEventTime,
                unreadCount: unreadCount,
                ownerID: ownerID,
                admins: JSONColumns.decode(adminsJSON) ?? [],
                participantsCount: participantsCount,
                isMuted: isMuted,
                description: descriptionText,
                isPinned: isPinned)
    }
}

struct MessageRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "message"

    var id: String
    var chatId: Int64
    var senderId: Int64?
    var text: String
    var timestamp: Int64
    var status: String
    var cid: Int64?
    var elementsJSON: String?
    var attachesJSON: String?
    var reactionsJSON: String?

    init(_ message: MaxMessage) {
        id = message.id
        chatId = message.chatID
        senderId = message.senderID
        text = message.text
        timestamp = message.timestamp
        status = message.status.rawValue
        cid = message.cid
        elementsJSON = JSONColumns.encode(message.elements.map(ElementDTO.init))
        attachesJSON = JSONColumns.encode(message.attachments.map(AttachmentDTO.init))
        reactionsJSON = JSONColumns.encode(message.reactions.map(ReactionDTO.init))
    }

    var domain: MaxMessage {
        // Тип для decode выводится из аннотации, а не из ?? [] —
        // иначе компилятор не может определить T и корень key-path.
        let elements: [ElementDTO] = JSONColumns.decode(elementsJSON) ?? []
        let attachments: [AttachmentDTO] = JSONColumns.decode(attachesJSON) ?? []
        let reactions: ReactionDTO? = JSONColumns.decode(reactionsJSON)
        return MaxMessage(id: id,
                          chatID: chatId,
                          senderID: senderId,
                          text: text,
                          timestamp: timestamp,
                          elements: elements.map(\.domain),
                          attachments: attachments.map(\.domain),
                          reactions: reactions?.domain,
                          cid: cid,
                          status: MaxMessageStatus(rawValue: status) ?? .sent)
    }
}

// MARK: - JSON-поля

enum JSONColumns {
    static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct ElementDTO: Codable {
    var kind: String
    var from: Int
    var length: Int
    var url: String?

    init(_ element: MaxMessageElement) {
        kind = element.kind.rawValue
        from = element.range.lowerBound
        length = element.range.count
        url = element.url?.absoluteString
    }

    var domain: MaxMessageElement {
        MaxMessageElement(kind: MaxMessageElement.Kind(rawValue: kind) ?? .unknown,
                          from: from,
                          length: length,
                          url: url.flatMap(URL.init(string:)))
    }
}

struct AttachmentDTO: Codable {
    var id: String
    var kind: String
    var url: String?
    var thumbnailURL: String?
    var fileName: String?
    var fileSize: Int64?
    var width: Int?
    var height: Int?
    var duration: Int?
    var title: String?
    var subtitle: String?

    init(_ attachment: MaxAttachment) {
        id = attachment.id
        kind = attachment.kind.rawValue
        url = attachment.url?.absoluteString
        thumbnailURL = attachment.thumbnailURL?.absoluteString
        fileName = attachment.fileName
        fileSize = attachment.fileSize
        width = attachment.width
        height = attachment.height
        duration = attachment.durationMillis
        title = attachment.title
        subtitle = attachment.subtitle
    }

    var domain: MaxAttachment {
        MaxAttachment(id: id,
                      kind: MaxAttachment.Kind(rawValue: kind) ?? .unknown,
                      url: url.flatMap(URL.init(string:)),
                      thumbnailURL: thumbnailURL.flatMap(URL.init(string:)),
                      fileName: fileName,
                      fileSize: fileSize,
                      width: width,
                      height: height,
                      durationMillis: duration,
                      title: title,
                      subtitle: subtitle)
    }
}

struct ReactionDTO: Codable {
    var counters: [String: Int]
    var yourReaction: String?
    var total: Int

    init(_ info: MaxReactionInfo) {
        counters = Dictionary(info.counters.map { ($0.reaction, $0.count) }, uniquingKeysWith: +)
        yourReaction = info.yourReaction
        total = info.totalCount
    }

    var domain: MaxReactionInfo {
        MaxReactionInfo(counters: counters.map { .init(reaction: $0.key, count: $0.value) }
                                     .sorted { $0.count > $1.count },
                        yourReaction: yourReaction,
                        totalCount: total)
    }
}

// MARK: - Репозитории

public final class MessageRepository {
    private let db: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.db = queue
    }

    public func save(items: [MaxMessage]) throws {
        guard !items.isEmpty else { return }
        try db.write { database in
            for item in items {
                try MessageRecord(item).upsert(database)
            }
        }
    }

    public func messages(chatID: MaxChatID, limit: Int = 60) throws -> [MaxMessage] {
        let records = try db.read { database in
            try MessageRecord
                .filter(Column("chatId") == chatID)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(database)
        }
        return records.reversed().map(\.domain)
    }

    public func olderMessages(chatID: MaxChatID, before timestamp: UnixMillis, limit: Int = 40) throws -> [MaxMessage] {
        let records = try db.read { database in
            try MessageRecord
                .filter(Column("chatId") == chatID && Column("timestamp") < timestamp)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(database)
        }
        return records.reversed().map(\.domain)
    }

    public func latest(chatID: MaxChatID) throws -> MaxMessage? {
        let record = try db.read { database in
            try MessageRecord.filter(Column("chatId") == chatID)
                .order(Column("timestamp").desc)
                .limit(1)
                .fetchOne(database)
        }
        return record?.domain
    }

    public func markFailed(id: MaxMessageID) throws {
        try db.write { database in
            try database.execute(sql: "UPDATE message SET status = 'failed' WHERE id = ?", arguments: [id])
        }
    }

    public func delete(id: MaxMessageID) throws {
        _ = try db.write { try MessageRecord.deleteOne($0, key: id) }
    }

    public func delete(ids: [MaxMessageID]) throws {
        guard !ids.isEmpty else { return }
        try db.write { database in
            try MessageRecord.deleteAll(database, keys: ids)
        }
    }

    public func deleteAll() throws {
        _ = try db.write { try MessageRecord.deleteAll($0) }
    }

    /// Обновляет счётчики реакций у сообщения.
    public func setReactions(_ info: MaxReactionInfo, messageID: MaxMessageID) throws {
        try db.write { database in
            guard var record = try MessageRecord.fetchOne(database, key: messageID) else { return }
            record.reactionsJSON = JSONColumns.encode(ReactionDTO(info))
            try record.update(database)
        }
    }

    /// Полнотекстовый поиск по локальной копии истории.
    public func search(_ query: String, limit: Int = 50) throws -> [MaxMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        let sanitized = "\"\(escaped)\""

        let records = try db.read { database in
            try MessageRecord.fetchAll(database, sql: """
                SELECT message.* FROM message
                JOIN message_search ON message_search.chatId = message.chatId
                WHERE message_search MATCH ?
                ORDER BY message.timestamp DESC
                LIMIT ?
                """, arguments: [sanitized, limit])
        }
        return records.map(\.domain)
    }
}

public final class ChatRepository {
    private let db: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.db = queue
    }

    public func save(chats: [MaxChat]) throws {
        try db.write { database in
            for chat in chats {
                try ChatRecord(chat).upsert(database)
            }
        }
    }

    public func save(chat: MaxChat) throws {
        try db.write { database in
            try ChatRecord(chat).upsert(database)
        }
    }

    public func chats() throws -> [MaxChat] {
        try db.read { database in
            let records = try ChatRecord
                .order(Column("isPinned").desc, Column("lastEventTime").desc)
                .fetchAll(database)
            return try records.map { record in
                var chat = record.domain
                chat.lastMessage = try MessageRecord
                    .filter(Column("chatId") == chat.id)
                    .order(Column("timestamp").desc)
                    .limit(1)
                    .fetchOne(database)?
                    .domain
                return chat
            }
        }
    }

    public func chat(id: MaxChatID) throws -> MaxChat? {
        try db.read { database in
            guard let record = try ChatRecord.fetchOne(database, key: id) else { return nil }
            var chat = record.domain
            chat.lastMessage = try MessageRecord
                .filter(Column("chatId") == id)
                .order(Column("timestamp").desc)
                .limit(1)
                .fetchOne(database)?
                .domain
            return chat
        }
    }

    public func incrementUnread(chatID: MaxChatID, delta: Int = 1, timestamp: UnixMillis) throws {
        try db.write { database in
            try database.execute(sql: """
                UPDATE chat
                SET unreadCount = CASE WHEN unreadCount < 0 THEN 0 ELSE unreadCount + ? END,
                    lastEventTime = MAX(lastEventTime, ?)
                WHERE id = ?
                """, arguments: [delta, timestamp, chatID])
        }
    }

    public func resetUnread(chatID: MaxChatID) throws {
        try db.write { database in
            try database.execute(sql: "UPDATE chat SET unreadCount = 0 WHERE id = ?", arguments: [chatID])
        }
    }

    public func deleteAll() throws {
        _ = try db.write { try ChatRecord.deleteAll($0) }
    }
}

public final class UserRepository {
    private let db: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.db = queue
    }

    public func save(users: [MaxUser]) throws {
        try db.write { database in
            for user in users {
                try UserRecord(user).upsert(database)
            }
        }
    }

    public func user(id: MaxUserID) throws -> MaxUser? {
        let record = try db.read { database in
            try UserRecord.fetchOne(database, key: id)
        }
        return record?.domain
    }

    public func users(ids: [MaxUserID]) throws -> [MaxUserID: MaxUser] {
        guard !ids.isEmpty else { return [:] }
        let records = try db.read { database in
            try UserRecord.filter(ids.contains(Column("id"))).fetchAll(database)
        }
        return Dictionary(records.map { ($0.id, $0.domain) }, uniquingKeysWith: { first, _ in first })
    }

    public func deleteAll() throws {
        _ = try db.write { try UserRecord.deleteAll($0) }
    }
}