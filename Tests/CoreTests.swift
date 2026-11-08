import Foundation
import XCTest
import GRDB
@testable import MaxClient

final class MessagePackTests: XCTestCase {
    func testRoundTripScalars() throws {
        let values: [MPValue] = [
            .null,
            .bool(true),
            .bool(false),
            .int(0),
            .int(127),
            .int(-1),
            .int(300),
            .int(70_000),
            .int(9_000_000_000_000),
            .int(Int64.min / 2),
            .double(3.14),
            .string("Привет, мир"),
            .string(""),
            .binary(Data([0, 1, 2, 3, 255]))
        ]

        for value in values {
            let encoded = MPEncoder.encode(value)
            let decoded = try MPDecoder.decode(encoded)
            XCTAssertEqual(decoded, value, "Failed for \(value)")
        }
    }

    func testRoundTripNested() throws {
        let value = MPValue([
            "chatId": .int(9_000_000_000_004),
            "message": MPValue([
                "text": .string("Привет"),
                "cid": .int(1_734_567_890_123),
                "elements": .array([]),
                "attaches": .array([MPValue(["_type": .string("PHOTO"), "width": .int(800)])])
            ]),
            "notify": .bool(true)
        ])

        let decoded = try MPDecoder.decode(MPEncoder.encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["message"]?["text"]?.string, "Привет")
        XCTAssertEqual(decoded["chatId"]?.int64, 9_000_000_000_004)
    }

    func testBinaryFrameEncoding() throws {
        let frame = MaxFrame(version: MaxProtocol.binaryVersion,
                             command: 0,
                             sequence: 7,
                             opcode: MaxOpcode.msgSend.rawValue,
                             payload: MPValue(["chatId": .int(1), "notify": .bool(true)]))
        let restored = try MaxFrame(binaryData: frame.binaryData())
        XCTAssertEqual(restored.opcode, MaxOpcode.msgSend.rawValue)
        XCTAssertEqual(restored.sequence, 7)
        XCTAssertEqual(restored.payload["chatId"]?.int64, 1)
    }

    func testJSONFrameDecoding() throws {
        let json = """
        {"ver":11,"cmd":0,"seq":3,"opcode":64,"payload":{"chatId":9000000000004,\
        "message":{"text":"Привет!","cid":1734567890123}}}
        """
        let frame = try MaxFrame(jsonData: Data(json.utf8))
        XCTAssertEqual(frame.opcode, 64)
        XCTAssertEqual(frame.sequence, 3)
        XCTAssertEqual(frame.payload["chatId"]?.int64, 9_000_000_000_004)
        XCTAssertEqual(frame.payload["message"]?["text"]?.string, "Привет!")
    }

    func testJSONFrameEncodingKeepsTypes() throws {
        let frame = MaxFrame(command: 0, sequence: 1, opcode: 6,
                             payload: MPValue(["deviceId": .string("abc"),
                                               "userAgent": MPValue(["deviceType": .string("IOS")])]))
        let object = try JSONSerialization.jsonObject(with: frame.jsonData()) as? [String: Any]
        XCTAssertEqual(object?["opcode"] as? Int, 6)
        XCTAssertNotNil(object?["payload"] as? [String: Any])
    }
}

final class ParserTests: XCTestCase {
    func testParseMessage() throws {
        let raw = MPValue([
            "id": .string("116762203424780659"),
            "time": .int(1_781_704_393_993),
            "type": .string("USER"),
            "sender": .int(9_000_000_000_003),
            "text": .string("текст"),
            "attaches": .array([]),
            "elements": .array([
                MPValue([
                    "type": .string("LINK"),
                    "from": .int(0),
                    "length": .int(5),
                    "attributes": MPValue(["url": .string("https://max.ru")])
                ])
            ])
        ])
        let message = try XCTUnwrap(MaxParser.message(from: raw, chatID: 42))
        XCTAssertEqual(message.id, "116762203424780659")
        XCTAssertEqual(message.senderID, 9_000_000_000_003)
        XCTAssertEqual(message.chatID, 42)
        XCTAssertEqual(message.text, "текст")
        XCTAssertEqual(message.elements.first?.kind, .link)
        XCTAssertEqual(message.elements.first?.url?.absoluteString, "https://max.ru")
    }

    func testParseChatWithParticipants() throws {
        let raw = MPValue([
            "id": .int(9_000_000_000_004),
            "type": .string("DIALOG"),
            "title": .string("Саша"),
            "status": .string("ACTIVE"),
            // Я и собеседник: peer(in:) возвращает того, кто не я.
            "participants": .map([
                MPMapKey("9000000000003"): .int(1_781_697_221_724),
                MPMapKey("9000000000004"): .int(1_781_697_221_725)
            ]),
            "lastEventTime": .int(1_781_700_000_000),
            "newMessages": .int(3)
        ])
        let chat = try XCTUnwrap(MaxParser.chat(from: raw))
        XCTAssertEqual(chat.id, 9_000_000_000_004)
        XCTAssertEqual(chat.type, .dialog)
        XCTAssertEqual(chat.unreadCount, 3)
        XCTAssertEqual(chat.participants.count, 2)
        XCTAssertNil(chat.peer(in: 9_000_000_000_005))
        XCTAssertEqual(chat.peer(in: 9_000_000_000_003), 9_000_000_000_004)
    }

    func testParseUserFromNamesArray() throws {
        let raw = MPValue([
            "id": .int(9_000_000_000_003),
            "names": .array([MPValue(["name": .string("Иван Петров"), "type": .string("FULL_NAME")])]),
            "phones": .array([MPValue(["number": .string("+71234567890"), "type": .string("MOBILE")])])
        ])
        let user = try XCTUnwrap(MaxParser.user(from: raw))
        XCTAssertEqual(user.fullName, "Иван Петров")
        XCTAssertEqual(user.phoneNumber, "+71234567890")
        XCTAssertEqual(user.initials, "ИП")
    }

    func testMessageEventMapping() {
        let frame = MaxFrame(command: 0, sequence: 0, opcode: MaxOpcode.msgSend.rawValue,
                             payload: MPValue(["chatId": .int(5),
                                               "message": MPValue(["id": .string("1"),
                                                                   "text": .string("hi"),
                                                                   "time": .int(100)])]))
        guard case .newMessage(let message, let chatID) = MaxEventMapper.map(frame: frame) else {
            return XCTFail("expected newMessage")
        }
        XCTAssertEqual(message.text, "hi")
        XCTAssertEqual(chatID, 5)
    }

    func testTypingEventMapping() {
        let frame = MaxFrame(command: 0, sequence: 0, opcode: MaxOpcode.notifTyping.rawValue,
                             payload: MPValue(["chatId": .int(5), "userId": .int(9)]))
        guard case .typing(let userID, let chatID) = MaxEventMapper.map(frame: frame) else {
            return XCTFail("expected typing")
        }
        XCTAssertEqual(userID, 9)
        XCTAssertEqual(chatID, 5)
    }

    func testRequestPayloadBuilders() {
        let payload = MaxRequests.sendMessage(chatID: 7, text: "hi", cid: 1)
        XCTAssertEqual(payload["chatId"]?.int64, 7)
        XCTAssertEqual(payload["message"]?["text"]?.string, "hi")
        XCTAssertEqual(payload["notify"]?.bool, true)

        let history = MaxRequests.history(chatID: 7, backward: 20, from: 1000)
        XCTAssertEqual(history["backward"]?.int64, 20)
        XCTAssertEqual(history["from"]?.int64, 1000)
        XCTAssertEqual(history["getMessages"]?.bool, true)
    }
}

final class PhoneFormatterTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(PhoneFormatter.normalize("89991234567"), "+79991234567")
        XCTAssertEqual(PhoneFormatter.normalize("+7 (999) 123-45-67"), "+79991234567")
        XCTAssertEqual(PhoneFormatter.normalize("9991234567"), "+79991234567")
        XCTAssertNil(PhoneFormatter.normalize("12345"))
    }

    func testMask() {
        XCTAssertEqual(PhoneFormatter.mask("89991234567"), "+7 999 123-45-67")
        XCTAssertEqual(PhoneFormatter.mask("+7 999"), "+7 999")
    }
}

/// Мультиплексирование ответов по seq — самое хрупкое место транспорта.
/// Проверяется без сети: «ответы» подаются прямо в pump.
final class FramePumpTests: XCTestCase {
    func testResponseGoesToMatchingRequest() async throws {
        let pump = MaxFramePump()
        let first = pump.nextSeq()
        let second = pump.nextSeq()

        let firstResponse = Task<MaxFrame, Error> {
            try await withCheckedThrowingContinuation { continuation in
                pump.registerAwaiting(first, continuation: continuation)
            }
        }
        let secondResponse = Task<MaxFrame, Error> {
            try await withCheckedThrowingContinuation { continuation in
                pump.registerAwaiting(second, continuation: continuation)
            }
        }

        await pump.waitUntilPending(2, timeout: 1)
        pump.completing(second, frame: MaxFrame(command: 1, sequence: second,
                                               opcode: MaxOpcode.getChats.rawValue))
        pump.completing(first, frame: MaxFrame(command: 1, sequence: first,
                                              opcode: MaxOpcode.getHistory.rawValue))

        let a = try await firstResponse.value
        let b = try await secondResponse.value
        XCTAssertEqual(a.opcode, MaxOpcode.getHistory.rawValue)
        XCTAssertEqual(b.opcode, MaxOpcode.getChats.rawValue)
    }

    func testTimeoutFailsOnlyItsRequest() async {
        let pump = MaxFramePump()
        let slow = pump.nextSeq()
        let fast = pump.nextSeq()

        let slowTask = Task<MaxFrame, Error> {
            try await withCheckedThrowingContinuation { continuation in
                pump.registerAwaiting(slow, continuation: continuation)
                pump.failLater(seq: slow, after: 0.05, error: MaxTransportError.timedOut(opcode: 49))
            }
        }
        let fastTask = Task<MaxFrame, Error> {
            try await withCheckedThrowingContinuation { continuation in
                pump.registerAwaiting(fast, continuation: continuation)
            }
        }

        await pump.waitUntilPending(2, timeout: 1)
        pump.completing(fast, frame: MaxFrame(command: 1, sequence: fast,
                                              opcode: MaxOpcode.getChats.rawValue))

        do {
            _ = try await fastTask.value
        } catch {
            XCTFail("быстрый запрос не должен упасть: \(error)")
        }

        do {
            _ = try await slowTask.value
            XCTFail("должен был сработать таймаут")
        } catch let error as MaxTransportError {
            XCTAssertEqual(error, .timedOut(opcode: 49))
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }
}

final class RepositoryTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        // В GRDB нет DatabaseQueue() без аргументов: база в памяти
        // открывается по специальному пути ":memory:". Каждый тест
        // получает чистую изолированную базу.
        queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
    }

    func testMessageRoundtripAndSearch() throws {
        let repository = MessageRepository(queue: queue)
        try repository.save(items: [MaxMessage(id: "1", chatID: 42, senderID: 7,
                                               text: "Привет, MAX!", timestamp: 1000, status: .sent)])

        let loaded = try repository.messages(chatID: 42)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "Привет, MAX!")

        let found = try repository.search("MAX")
        XCTAssertEqual(found.count, 1, "полнотекстовый индекс должен найти сообщение")
    }

    func testUnreadCounterAndOrdering() throws {
        let chats = ChatRepository(queue: queue)
        try chats.save(chats: [
            MaxChat(id: 1, type: .dialog, title: "А", lastEventTime: 100),
            MaxChat(id: 2, type: .dialog, title: "Б", lastEventTime: 200)
        ])
        try chats.incrementUnread(chatID: 1, timestamp: 300)

        let list = try chats.chats()
        XCTAssertEqual(list.first?.id, 1, "более свежий чат — выше")
        XCTAssertEqual(list.first?.unreadCount, 1)

        try chats.resetUnread(chatID: 1)
        XCTAssertEqual(try chats.chats().first?.unreadCount, 0)
    }

    func testMessageDeleteRemovesFromIndex() throws {
        let repository = MessageRepository(queue: queue)
        try repository.save(items: [MaxMessage(id: "9", chatID: 1, senderID: 1,
                                               text: "удали меня", timestamp: 10)])
        XCTAssertEqual(try repository.search("удали").count, 1)
        try repository.delete(id: "9")
        XCTAssertEqual(try repository.search("удали").count, 0)
        XCTAssertTrue(try repository.messages(chatID: 1).isEmpty)
    }
}