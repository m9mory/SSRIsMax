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
