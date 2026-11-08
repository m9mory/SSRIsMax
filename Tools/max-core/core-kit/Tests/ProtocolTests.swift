import XCTest
@testable import MaxCore

/// Офлайн-проверки ядра: протокол, кодирование, парсеры.
/// Идут без сети и без iOS — поэтому прогоняются в CI на macOS.
final class ProtocolTests: XCTestCase {
    func testMessagePackScalars() throws {
        let values: [MPValue] = [
            .null, .bool(true), .bool(false),
            .int(0), .int(-1), .int(127), .int(300), .int(70_000),
            .int(9_000_000_000_004), .int(Int64.min / 2),
            .double(3.14),
            .string("Привет, мир"), .string(""),
            .binary(Data([0, 1, 2, 255]))
        ]
        for value in values {
            let decoded = try MPDecoder.decode(MPEncoder.encode(value))
            XCTAssertEqual(decoded, value, "round-trip failed for \(value)")
        }
    }

    func testMessagePackNested() throws {
        let value: MPValue = [
            "chatId": .int(9_000_000_000_004),
            "message": [
                "text": "Привет",
                "cid": .int(1_734_567_890_123),
                "elements": .array([]),
                "attaches": .array([["_type": "PHOTO", "width": .int(800)]])
            ],
            "notify": .bool(true)
        ]
        let decoded = try MPDecoder.decode(MPEncoder.encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["message"]?["text"]?.string, "Привет")
    }

    func testBinaryFrame() throws {
        let frame = MaxFrame(version: MaxProtocol.binaryVersion,
                             command: 0,
                             sequence: 7,
                             opcode: MaxOpcode.msgSend.rawValue,
                             payload: ["chatId": .int(1)])
        let restored = try MaxFrame(binaryData: frame.binaryData())
        XCTAssertEqual(restored.opcode, MaxOpcode.msgSend.rawValue)
        XCTAssertEqual(restored.sequence, 7)
        XCTAssertEqual(restored.payload["chatId"]?.int64, 1)
    }

    func testJSONFrame() throws {
        let json = """
        {"ver":11,"cmd":0,"seq":3,"opcode":64,"payload":{"chatId":9000000000004}}
        """
        let frame = try MaxFrame(jsonData: Data(json.utf8))
        XCTAssertEqual(frame.opcode, 64)
        XCTAssertEqual(frame.sequence, 3)
        XCTAssertEqual(frame.payload["chatId"]?.int64, 9_000_000_000_004)
    }

    func testParseMessageAndChat() throws {
        let message = try XCTUnwrap(MaxParser.message(from: [
            "id": "116762203424780659",
            "time": .int(1_781_704_393_993),
            "sender": .int(9_000_000_000_003),
            "text": "текст",
            "elements": .array([["type": "LINK", "from": .int(0), "length": .int(5),
                                "attributes": ["url": "https://max.ru"]]])
        ], chatID: 42))
        XCTAssertEqual(message.senderID, 9_000_000_000_003)
        XCTAssertEqual(message.elements.first?.url?.absoluteString, "https://max.ru")

        let chat = try XCTUnwrap(MaxParser.chat(from: [
            "id": .int(9_000_000_000_004),
            "type": "DIALOG",
            "title": "Саша",
            "participants": ["9000000000003": .int(1_781_697_221_724)],
            "newMessages": .int(3)
        ]))
        XCTAssertEqual(chat.type, .dialog)
        XCTAssertEqual(chat.unreadCount, 3)
        XCTAssertEqual(chat.peer(in: 9_000_000_000_003), 9_000_000_000_004)
    }

    func testEventMapping() {
        let frame = MaxFrame(command: 0, sequence: 0,
                             opcode: MaxOpcode.msgSend.rawValue,
                             payload: ["chatId": .int(5),
                                       "message": ["id": "1", "text": "hi", "time": .int(1)]])
        guard case .newMessage(let message, let chatID) = MaxEventMapper.map(frame: frame) else {
            return XCTFail("ожидалось newMessage")
        }
        XCTAssertEqual(message.text, "hi")
        XCTAssertEqual(chatID, 5)
    }

    func testTCPFraming() throws {
        let frame = MaxFrame(sequence: 5, opcode: MaxOpcode.getChats.rawValue,
                             payload: ["count": .int(10)])
        let packet = MaxTCPTransport.pack(frame)
        let length = Int(packet[6]) << 24 | Int(packet[7]) << 16 | Int(packet[8]) << 8 | Int(packet[9])
        XCTAssertEqual(length, packet.count - 10)
        let payload = try MaxTCPTransport.decodePayload(packet.subdata(in: 10..<packet.count))
        XCTAssertEqual(payload.arrayItems.count, 5)
    }
}

/// Телефон, запросы и разбор списков — то, что чаще всего ломается
/// при изменениях протокола, но не требует iOS.
final class RequestTests: XCTestCase {
    func testPhoneNormalization() {
        XCTAssertEqual(PhoneFormatter.normalize("89991234567"), "+79991234567")
        XCTAssertEqual(PhoneFormatter.normalize("+7 (999) 123-45-67"), "+79991234567")
        XCTAssertEqual(PhoneFormatter.normalize("9991234567"), "+79991234567")
        XCTAssertNil(PhoneFormatter.normalize("12345"))
        XCTAssertNil(PhoneFormatter.normalize(""))
    }

    func testPhoneMask() {
        XCTAssertEqual(PhoneFormatter.mask("89991234567"), "+7 999 123-45-67")
        XCTAssertEqual(PhoneFormatter.mask("+7 999"), "+7 999")
        XCTAssertEqual(PhoneFormatter.mask(""), "+7 ")
    }

    func testSendMessagePayload() {
        let payload = MaxRequests.sendMessage(chatID: 7, text: "hi", cid: 1)
        XCTAssertEqual(payload["chatId"]?.int64, 7)
        XCTAssertEqual(payload["message"]?["text"]?.string, "hi")
        XCTAssertEqual(payload["message"]?["cid"]?.int64, 1)
        XCTAssertEqual(payload["notify"]?.bool, true)
    }

    func testHistoryRequiresFrom() {
        // GET_HISTORY с backward > 0 без `from` возвращает пусто — проверяем,
        // что построитель запроса всегда кладёт `from`.
        let payload = MaxRequests.history(chatID: 7, backward: 20, from: 1000)
        XCTAssertEqual(payload["backward"]?.int64, 20)
        XCTAssertEqual(payload["from"]?.int64, 1000)
        XCTAssertEqual(payload["getMessages"]?.bool, true)
    }

    func testChatsAndUsersParsing() {
        let chats = MaxParser.chats(from: [
            "chats": .array([
                ["id": .int(1), "type": "DIALOG", "title": "А", "newMessages": .int(2)],
                ["id": .int(2), "type": "CHAT", "title": "Б", "newMessages": .int(0)]
            ])
        ])
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats.first?.unreadCount, 2)
        XCTAssertEqual(chats.last?.type, .chat)

        // users() принимает и голый массив, и обёртку — проверяем оба вида.
        let users = MaxParser.users(from: [
            ["id": .int(9_000_000_000_003),
             "names": .array([["name": "Иван Петров", "type": "FULL_NAME"]])]
        ])
        XCTAssertEqual(users.first?.fullName, "Иван Петров")
        XCTAssertEqual(users.first?.initials, "ИП")

        let wrapped = MaxParser.users(from: ["contacts": .array([["id": .int(5)]])])
        XCTAssertEqual(wrapped.first?.id, 5)
        XCTAssertEqual(wrapped.first?.fullName, "Пользователь 5")
    }
}

/// Мультиплексирование ответов по seq — самая тонкая часть транспорта.
/// Проверяется без сети: подсовываем «ответы» напрямую в pump.
final class FramePumpTests: XCTestCase {
    func testSeqWrapsAndSkipsZero() {
        let pump = MaxFramePump()
        var seen = Set<Int>()
        for _ in 0..<100 {
            let seq = pump.nextSeq()
            XCTAssertGreaterThan(seq, 0)
            XCTAssertLessThanOrEqual(seq, 65535)
            seen.insert(seq)
        }
        XCTAssertEqual(seen.count, 100, "seq не должен повторяться на короткой серии")
    }

    /// Ответ должен попасть именно в свой запрос, даже если запросы идут
    /// параллельно и отвечают не по порядку.
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

        // Даём задачам зарегистрироваться, иначе ответ придёт «в пустоту».
        await pump.waitUntilPending(2, timeout: 1)

        // Отвечаем в обратном порядке — перепутать легко, тест это ловит.
        pump.completing(second, frame: MaxFrame(command: 1, sequence: second,
                                               opcode: MaxOpcode.getChats.rawValue))
        pump.completing(first, frame: MaxFrame(command: 1, sequence: first,
                                              opcode: MaxOpcode.getHistory.rawValue))

        let a = try await firstResponse.value
        let b = try await secondResponse.value
        XCTAssertEqual(a.opcode, MaxOpcode.getHistory.rawValue)
        XCTAssertEqual(b.opcode, MaxOpcode.getChats.rawValue)
    }

    /// Таймаут срабатывает только у своего запроса: соседний, которому
    /// ответ пришёл вовремя, не должен упасть.
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

    /// Обрыв соединения должен разбудить все ожидающие запросы, иначе
    /// UI зависнет в вечном спиннере.
    func testFailAllResumesEveryone() async {
        let pump = MaxFramePump()
        let first = pump.nextSeq()
        let second = pump.nextSeq()

        let tasks = [first, second].map { seq in
            Task<MaxFrame, Error> {
                try await withCheckedThrowingContinuation { continuation in
                    pump.registerAwaiting(seq, continuation: continuation)
                }
            }
        }

        await pump.waitUntilPending(2, timeout: 1)
        pump.failAll(MaxTransportError.closed("соединение закрыто"))

        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("ожидалась ошибка соединения")
            } catch let error as MaxTransportError {
                XCTAssertEqual(error, .closed("соединение закрыто"))
            } catch {
                XCTFail("неожиданная ошибка: \(error)")
            }
        }
    }
}
