import Foundation

/// Парсеры JSON-представления протокола MAX в доменные модели.
///
/// Отдельный слой, потому что сервер возвращает «сырой» словарь с массой
/// необязательных полей и разными типами (`id` бывает и числом, и строкой).
public enum MaxParser {
    // MARK: - Примитивы

    static func int64(_ value: MPValue?) -> Int64? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    static func string(_ value: MPValue?) -> String? {
        value?.string
    }

    static func url(_ value: MPValue?) -> URL? {
        guard let s = string(value), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static func time(_ value: MPValue?) -> UnixMillis {
        int64(value) ?? 0
    }

    /// Текущее время в миллисекундах. Нужно для дефолтных аргументов
    /// из `public` API, поэтому `public`.
    public static func nowMillis() -> UnixMillis {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Обращение к примитивам из замыканий, где локальные имена (`url`)
    /// затеняют статические методы парсера.
    private enum helper {
        static func url(_ value: MPValue?) -> URL? { MaxParser.url(value) }
    }

    // MARK: - Пользователи

    public static func user(from value: MPValue, fallbackID: MaxUserID? = nil) -> MaxUser? {
        let id = int64(value["id"]) ?? int64(value["userId"]) ?? fallbackID
        guard let id else { return nil }

        var firstName = string(value["firstname"]) ?? string(value["firstName"])
        var lastName = string(value["lastname"]) ?? string(value["lastName"])
        var fullName = string(value["name"]) ?? string(value["fullName"]) ?? ""

        // names[] содержит FULL_NAME, иногда отдельно FIRST_NAME / LAST_NAME.
        for entry in value["names"]?.arrayItems ?? [] {
            switch string(entry["type"]) {
            case "FULL_NAME": fullName = string(entry["name"]) ?? fullName
            case "FIRST_NAME": firstName = string(entry["name"]) ?? firstName
            case "LAST_NAME": lastName = string(entry["name"]) ?? lastName
            default: break
            }
        }

        if fullName.isEmpty {
            fullName = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        }

        let phone = value["phones"]?.arrayItems.first.flatMap { string($0["number"]) }
            ?? string(value["phone"])
            ?? string(value["phoneNumber"])

        let avatar = url(value["picture"]?["url"]) ?? url(value["baseIconUrl"])
        let botFlag = int64(value["isBot"]).map { $0 != 0 } ?? (value["isBot"]?.bool ?? false)

        return MaxUser(id: id,
                       firstName: firstName,
                       lastName: lastName,
                       fullName: fullName.isEmpty ? "Без имени" : fullName,
                       phoneNumber: phone,
                       about: string(value["about"]),
                       avatarURL: avatar,
                       isBot: botFlag)
    }

    public static func users(from value: MPValue?) -> [MaxUser] {
        let raw = value?.arrayItems ?? (value?["contacts"]?.arrayItems ?? [])
        return raw.compactMap { entry -> MaxUser? in
            if let user = user(from: entry) { return user }
            // Часто приходит {id, type} — берём хотя бы id.
            if let id = int64(entry["id"]) ?? int64(entry["userId"]) {
                return MaxUser(id: id, fullName: "Пользователь \(id)")
            }
            return nil
        }
    }

    // MARK: - Чаты

    public static func chat(from value: MPValue) -> MaxChat? {
        guard let id = int64(value["id"]) ?? int64(value["chatId"]) else { return nil }

        var participants: [MaxUserID: UnixMillis] = [:]
        let participantsMap = value["participants"]?.mapEntries ?? value["members"]?.mapEntries ?? [:]
        for (key, stamp) in participantsMap {
            guard let uid = Int64(key.description) else { continue }
            participants[uid] = stamp.int64 ?? 0
        }

        let title = string(value["title"]) ?? string(value["name"]) ?? "Без названия"
        let lastEvent = time(value["lastEventTime"])
        let modified = time(value["modified"])

        return MaxChat(
            id: id,
            type: MaxChatType(raw: string(value["type"])),
            title: title,
            avatarURL: url(value["picture"]?["url"]) ?? url(value["baseIconUrl"]),
            status: MaxChatStatus(rawValue: string(value["status"]) ?? "ACTIVE") ?? .active,
            participants: participants,
            lastMessage: value["lastMessage"].flatMap { message(from: $0, chatID: id) },
            lastEventTime: lastEvent != 0 ? lastEvent : modified,
            unreadCount: Int(int64(value["newMessages"]) ?? int64(value["unread"]) ?? 0),
            ownerID: int64(value["owner"]) ?? 0,
            admins: (value["admins"]?.arrayItems ?? []).compactMap { int64($0) },
            participantsCount: Int(int64(value["participantsCount"]) ?? Int64(participants.count)),
            isMuted: (value["options"]?["MUTED"]?.bool ?? false) || (value["muted"]?.bool ?? false),
            description: string(value["description"]),
            isPinned: value["pinned"]?.bool ?? false
        )
    }

    public static func chats(from value: MPValue?) -> [MaxChat] {
        guard let value else { return [] }
        return value["chats"]?.arrayItems.compactMap { chat(from: $0) } ?? []
    }

    // MARK: - Сообщения

    public static func message(from value: MPValue, chatID: MaxChatID) -> MaxMessage? {
        guard let id = string(value["id"]) ?? string(value["messageId"]) else { return nil }
        let sender = int64(value["sender"]) ?? int64(value["senderId"])
        let cid = int64(value["cid"])
        let time = time(value["time"])
        let timestamp = time != 0 ? time : self.time(value["timestamp"])

        return MaxMessage(
            id: id,
            chatID: int64(value["chatId"]) ?? chatID,
            senderID: sender,
            text: string(value["text"]) ?? "",
            timestamp: timestamp,
            elements: elements(from: value["elements"]),
            attachments: attachments(from: value["attaches"]),
            reactions: reactions(from: value["reactionInfo"]),
            cid: cid,
            status: string(value["status"]) == "EDITED" ? .edited : .sent,
            isReadByMe: true
        )
    }

    public static func messages(from value: MPValue?, chatID: MaxChatID) -> [MaxMessage] {
        (value?["messages"]?.arrayItems ?? []).compactMap { message(from: $0, chatID: chatID) }
    }

    static func elements(from value: MPValue?) -> [MaxMessageElement] {
        (value?.arrayItems ?? []).compactMap { entry in
            guard let length = int64(entry["length"]) else { return nil }
            let from = Int(int64(entry["from"]) ?? 0)
            let kind = MaxMessageElement.Kind(rawValue: string(entry["type"]) ?? "") ?? .unknown
            return MaxMessageElement(kind: kind,
                                     from: from,
                                     length: Int(length),
                                     url: url(entry["attributes"]?["url"]))
        }
    }

    static func attachments(from value: MPValue?) -> [MaxAttachment] {
        (value?.arrayItems ?? []).compactMap { entry in
            let typeRaw = string(entry["_type"]) ?? string(entry["type"])
            let kind = MaxAttachment.Kind(rawValue: typeRaw ?? "")
                ?? (entry["keyboard"] != nil ? .keyboard : .unknown)

            var raw: [String: String] = [:]
            for (key, val) in entry.mapEntries {
                if let s = val.string { raw[key.description] = s }
            }

            let remoteURL = helper.url(entry["url"])
                ?? helper.url(entry["fileUrl"])
                ?? helper.url(entry["baseUrl"])
                ?? helper.url(entry["photoUrl"])

            let thumb = helper.url(entry["thumbnail"]?["url"])
                ?? helper.url(entry["preview"]?["url"])
                ?? helper.url(entry["thumbUrl"])

            return MaxAttachment(
                id: string(entry["fileId"]) ?? string(entry["photoId"]) ?? UUID().uuidString,
                kind: kind,
                url: remoteURL,
                thumbnailURL: thumb,
                fileName: string(entry["fileName"]) ?? string(entry["name"]),
                fileSize: int64(entry["fileSize"]) ?? int64(entry["size"]),
                width: int64(entry["width"]).map(Int.init),
                height: int64(entry["height"]).map(Int.init),
                durationMillis: int64(entry["duration"]).map(Int.init),
                title: string(entry["title"]),
                subtitle: string(entry["description"]) ?? string(entry["subtitle"]),
                raw: raw
            )
        }
    }

    static func reactions(from value: MPValue?) -> MaxReactionInfo? {
        guard let value, value != .null else { return nil }
        let counters = (value["counters"]?.arrayItems ?? []).compactMap { entry -> MaxReactionInfo.Counter? in
            guard let reaction = string(entry["reaction"]) ?? string(entry["emoji"]) else { return nil }
            return .init(reaction: reaction, count: Int(int64(entry["count"]) ?? 0))
        }
        return MaxReactionInfo(counters: counters,
                               yourReaction: string(value["yourReaction"]),
                               totalCount: Int(int64(value["totalCount"]) ?? Int64(counters.reduce(0) { $0 + $1.count })))
    }
}

// MARK: - Сборка запросов

public enum MaxRequests {
    public struct UserAgent: Sendable {
        public var deviceType: String
        public var pushDeviceType: String
        public var locale: String
        public var osVersion: String
        public var deviceName: String
        public var appVersion: String
        public var timezone: String
        public var screen: String

        public init(deviceType: String = "IOS",
                    pushDeviceType: String = "APNS",
                    locale: String = "ru",
                    osVersion: String = "iOS",
                    deviceName: String = "iPhone",
                    appVersion: String = MaxProtocol.appVersion,
                    timezone: String = TimeZone.current.identifier,
                    screen: String = "390x844 3.0x") {
            self.deviceType = deviceType
            self.pushDeviceType = pushDeviceType
            self.locale = locale
            self.osVersion = osVersion
            self.deviceName = deviceName
            self.appVersion = appVersion
            self.timezone = timezone
            self.screen = screen
        }

        public var payload: MPValue {
            MPValue([
                "deviceType": .string(deviceType),
                "pushDeviceType": .string(pushDeviceType),
                "locale": .string(locale),
                "deviceLocale": .string(locale),
                "osVersion": .string(osVersion),
                "deviceName": .string(deviceName),
                "headerUserAgent": .string("MaxClient/\(appVersion) (iOS)"),
                "appVersion": .string(appVersion),
                "screen": .string(screen),
                "timezone": .string(timezone)
            ])
        }
    }

    public static func initSession(deviceID: String, userAgent: UserAgent) -> MPValue {
        MPValue(["deviceId": .string(deviceID), "userAgent": userAgent.payload])
    }

    public static func requestCode(phone: String, type: String = "START_AUTH", captchaToken: String? = nil) -> MPValue {
        var payload: [String: MPValue] = [
            "phone": .string(phone),
            "type": .string(type),
            "language": .string("ru")
        ]
        if let captchaToken { payload["captchaToken"] = .string(captchaToken) }
        return MPValue(payload)
    }

    public static func enterCode(token: String, code: String) -> MPValue {
        MPValue([
            "token": .string(token),
            "verifyCode": .string(code),
            "authTokenType": .string("CHECK_CODE")
        ])
    }

    public static func login(token: String, chatsCount: Int = MaxProtocol.loginChatsCount) -> MPValue {
        MPValue([
            "token": .string(token),
            "interactive": .bool(true),
            "chatsCount": .int(Int64(chatsCount)),
            "chatsSync": .int(Int64(chatsCount)),
            "contactsSync": .int(0),
            "presenceSync": .int(0),
            "draftsSync": .int(0)
        ])
    }

    public static func chats(count: Int = 100, marker: UnixMillis = nowMillis()) -> MPValue {
        MPValue(["count": .int(Int64(count)), "marker": .int(marker)])
    }

    public static func history(chatID: MaxChatID, backward: Int = 50, forward: Int = 0, from: UnixMillis) -> MPValue {
        MPValue([
            "chatId": .int(chatID),
            "backward": .int(Int64(backward)),
            "forward": .int(Int64(forward)),
            "backwardTime": .int(0),
            "forwardTime": .int(0),
            "getChat": .bool(false),
            "getMessages": .bool(true),
            "from": .int(from),
            "interactive": .bool(false)
        ])
    }

    public static func sendMessage(chatID: MaxChatID, text: String, cid: Int64, attachments: [MPValue] = []) -> MPValue {
        MPValue([
            "chatId": .int(chatID),
            "notify": .bool(true),
            "message": MPValue([
                "text": .string(text),
                "cid": .int(cid),
                "elements": .array([]),
                "attaches": .array(attachments)
            ])
        ])
    }

    public static func typing(chatID: MaxChatID) -> MPValue {
        MPValue(["chatId": .int(chatID)])
    }

    public static func markRead(chatID: MaxChatID, messageID: MaxMessageID, mark: UnixMillis) -> MPValue {
        MPValue([
            "type": .string("READ_MESSAGE"),
            "chatId": .int(chatID),
            "messageId": .string(messageID),
            "mark": .int(mark)
        ])
    }

    public static func subscribe(chatID: MaxChatID, subscribe: Bool = true) -> MPValue {
        MPValue(["chatId": .int(chatID), "subscribe": .bool(subscribe)])
    }

    public static func chatInfo(chatID: MaxChatID) -> MPValue {
        MPValue(["chatId": .int(chatID)])
    }

    public static func chatBulk(ids: [MaxChatID]) -> MPValue {
        MPValue(["chatIds": .array(ids.map { .int($0) })])
    }

    public static func react(chatID: MaxChatID, messageID: MaxMessageID, emoji: String) -> MPValue {
        MPValue([
            "chatId": .int(chatID),
            "messageId": .int(Int64(messageID) ?? 0),
            "reaction": MPValue([
                "reactionType": .string("EMOJI"),
                "id": .string(emoji)
            ])
        ])
    }

    public static func unreact(chatID: MaxChatID, messageID: MaxMessageID) -> MPValue {
        MPValue(["chatId": .int(chatID), "messageId": .int(Int64(messageID) ?? 0)])
    }

    public static func edit(chatID: MaxChatID, messageID: MaxMessageID, text: String) -> MPValue {
        MPValue([
            "chatId": .int(chatID),
            "messageId": .string(messageID),
            "text": .string(text),
            "elements": .array([]),
            "attachments": .array([])
        ])
    }

    public static func delete(chatID: MaxChatID, messageID: MaxMessageID, forMe: Bool) -> MPValue {
        MPValue([
            "chatId": .int(chatID),
            "messageIds": .array([.int(Int64(messageID) ?? 0)]),
            "forMe": .bool(forMe)
        ])
    }

    public static func contactByPhone(_ phone: String) -> MPValue {
        MPValue(["phone": .string(phone)])
    }
}
