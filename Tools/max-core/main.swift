import Foundation

/// CLI-харнесс ядра MAX-клиента.
///
/// Собирается отдельно от iOS-приложения, чтобы можно было проверять
/// протокол прямо с десктопа (SwiftPM: macOS, Linux, Windows):
///
///     swift run max-core selftest
///     swift run max-core ping
///     swift run max-core auth +79991234567
///
/// Файлы ядра компилируются без SwiftUI, UIKit и GRDB — общий код
/// между приложением и CLI живёт в одном месте.

// MARK: - CLI

struct CLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        let values = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "selftest":
            SelfTest.run()
        case "ping":
            await NetworkCheck.ping()
        case "auth":
            guard let phone = values.first else {
                print("Укажите номер: max-core auth +79991234567")
                exit(64)
            }
            await NetworkCheck.interactiveAuth(phone: phone)
        case "dump":
            guard let path = values.first else {
                print("Укажите путь к файлу с кадром (JSON)")
                exit(64)
            }
            DebugDump.run(path: path)
        default:
            print("Неизвестная команда: \(command)")
            printUsage()
            exit(64)
        }
    }

    static func printUsage() {
        print("""
        max-core — CLI для проверки ядра клиента MAX

        Команды:
          selftest           тесты протокола без сети (кодек, парсеры, кадры)
          ping               подключиться к ws-api.oneme.ru и отправить INIT
          auth <телефон>     войти по SMS и вывести список чатов
          dump <файл.json>   разобрать сохранённый кадр (удобно для отладки)

        Переменные окружения:
          MAX_TRANSPORT=ws|tcp   транспорт (по умолчанию ws)
          MAX_VERBOSE=1          печатать каждый кадр
        """)
    }
}

// MARK: - Self-test

/// Тесты без сети: кодирование, кадры и парсеры.
enum SelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("  ok   \(name)")
        } else {
            print("  FAIL \(name)")
            failures += 1
        }
    }

    static func run() {
        print("MessagePack:")
        roundTrip(.null, "null")
        roundTrip(.bool(true), "bool")
        roundTrip(.int(0), "int 0")
        roundTrip(.int(-1), "negative fixint")
        roundTrip(.int(300), "int16")
        roundTrip(.int(70_000), "int32")
        roundTrip(.int(9_000_000_000_004), "int64 chatId")
        roundTrip(.string("Привет, мир"), "utf8 string")
        roundTrip(.binary(Data([0, 1, 2, 255])), "binary")
        roundTrip(MPValue(["a": .int(1), "b": .array([.bool(true), .string("x")])]), "nested map")

        print("Frames:")
        let frame = MaxFrame(version: 10, command: 0, sequence: 7,
                             opcode: MaxOpcode.msgSend.rawValue,
                             payload: MPValue(["chatId": .int(9_000_000_000_004), "notify": .bool(true)]))
        if let restored = try? MaxFrame(binaryData: frame.binaryData()) {
            check(restored.opcode == 64, "binary frame opcode")
            check(restored.sequence == 7, "binary frame seq")
            check(restored.payload["chatId"]?.int64 == 9_000_000_000_004, "binary frame payload")
        } else {
            check(false, "binary frame round-trip")
        }

        let packet = MaxTCPTransport.pack(frame)
        if let payload = try? MaxTCPTransport.decodePayload(packet.subdata(in: 10..<packet.count)) {
            check(payload.arrayItems.count == 5, "tcp header + payload")
        } else {
            check(false, "tcp header + payload")
        }

        let json = """
        {"ver":11,"cmd":0,"seq":3,"opcode":64,"payload":{"chatId":9000000000004,\
        "message":{"text":"Привет!","cid":1734567890123}}}
        """
        if let parsed = try? MaxFrame(jsonData: Data(json.utf8)) {
            check(parsed.opcode == 64, "json opcode")
            check(parsed.payload["chatId"]?.int64 == 9_000_000_000_004, "json big int")
            check(parsed.payload["message"]?["text"]?.string == "Привет!", "json nested text")
        } else {
            check(false, "json frame parse")
        }

        print("Parsers:")
        let message = MaxParser.message(from: MPValue([
            "id": .string("116762203424780659"),
            "time": .int(1_781_704_393_993),
            "sender": .int(9_000_000_000_003),
            "text": .string("текст"),
            "elements": .array([
                MPValue([
                    "type": .string("LINK"),
                    "from": .int(0),
                    "length": .int(5),
                    "attributes": MPValue(["url": .string("https://max.ru")])
                ])
            ])
        ]), chatID: 42)
        check(message?.senderID == 9_000_000_000_003, "parse message sender")
        check(message?.elements.first?.url?.absoluteString == "https://max.ru", "parse link element")

        let chat = MaxParser.chat(from: MPValue([
            "id": .int(9_000_000_000_004),
            "type": .string("DIALOG"),
            "title": .string("Саша"),
            "participants": .map([MPMapKey("9000000000003"): .int(1_781_697_221_724)]),
            "newMessages": .int(3)
        ]))
        check(chat?.type == .dialog, "parse chat type")
        check(chat?.unreadCount == 3, "parse unread")
        check(chat?.peer(in: 9_000_000_000_003) == 9_000_000_000_004, "dialog peer")

        let event = MaxEventMapper.map(frame: MaxFrame(command: 0, sequence: 0,
                                                       opcode: MaxOpcode.msgSend.rawValue,
                                                       payload: MPValue([
                                                           "chatId": .int(5),
                                                           "message": MPValue([
                                                               "id": .string("1"),
                                                               "text": .string("hi"),
                                                               "time": .int(1)
                                                           ])
                                                       ])))
        if case .newMessage(let mapped, let chatID) = event {
            check(mapped.text == "hi" && chatID == 5, "push → newMessage")
        } else {
            check(false, "push → newMessage")
        }

        print("")
        if failures == 0 {
            print("Всё в порядке ✅")
        } else {
            print("Провалено проверок: \(failures) ❌")
            exit(1)
        }
    }

    static func roundTrip(_ value: MPValue, _ name: String) {
        let data = MPEncoder.encode(value)
        guard let decoded = try? MPDecoder.decode(data) else {
            check(false, "\(name): decode threw")
            return
        }
        check(decoded == value, name)
    }
}

// MARK: - Сеть

enum NetworkCheck {
    static var transport: MaxTransporting {
        ProcessInfo.processInfo.environment["MAX_TRANSPORT"] == "tcp"
            ? MaxTCPTransport()
            : MaxWebSocketTransport()
    }

    final class InMemoryStore: MaxCredentialStore {
        var deviceID = UUID().uuidString.lowercased()
        var accessToken: String?
        var currentUserID: MaxUserID?
        func clearSession() { accessToken = nil; currentUserID = nil }
    }

    static func ping() async {
        let t = transport
        do {
            try await t.connect()
            let auth = MaxAuthService(transport: t, store: NetworkCheck.InMemoryStore())
            try await auth.initialize()
            print("INIT прошёл — соединение с ws-api.oneme.ru работает ✅")
        } catch {
            print("Ошибка INIT: \(error)")
            t.disconnect()
            exit(1)
        }
        t.disconnect()
    }

    static func interactiveAuth(phone: String) async {
        let t = transport
        let store = NetworkCheck.InMemoryStore()
        let auth = MaxAuthService(transport: t, store: store)

        do {
            print("Подключаемся…")
            let verification = try await auth.requestCode(phone: phone)
            print("SMS отправлено на \(phone). Длина кода: \(verification.codeLength)")
            print("Введите код: ", terminator: "")
            guard let code = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                exit(1)
            }
            let token = try await auth.confirmCode(token: verification.token, code: code)
            print("Код принят, входим…")
            let result = try await auth.login(token: token)
            print("Вы вошли как \(result.profile.fullName) (id \(result.profile.id))")
            print("Чатов: \(result.chats.count)")
            for chat in result.chats.prefix(10) {
                print("  [\(chat.id)] \(chat.title) — \(ChatFormatting.preview(chat.lastMessage))")
            }
        } catch {
            print("Ошибка: \(error.localizedDescription)")
            t.disconnect()
            exit(1)
        }
        t.disconnect()
    }
}

enum DebugDump {
    static func run(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("Файл не найден: \(path)")
            exit(1)
        }
        if let frame = try? MaxFrame(jsonData: data) {
            print("JSON-кадр: cmd=\(frame.command) seq=\(frame.sequence) opcode=\(frame.opcode)")
            if let pretty = try? JSONSerialization.data(withJSONObject: frame.payload.foundation,
                                                        options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                print(text)
            }
            return
        }
        if let value = try? MPDecoder.decode(data) {
            print("MessagePack: \(value)")
            return
        }
        print("Не удалось разобрать файл")
        exit(1)
    }
}

/// Превью сообщения без UIKit (для CLI).
enum ChatFormatting {
    static func preview(_ message: MaxMessage?) -> String {
        guard let message else { return "нет сообщений" }
        if let attachment = message.attachments.first {
            switch attachment.kind {
            case .photo: return "📷 фото"
            case .video: return "🎬 видео"
            case .file: return "📎 \(attachment.fileName ?? "файл")"
            case .audio: return "🎤 голосовое"
            default: break
            }
        }
        return message.text.isEmpty ? "(без текста)" : message.text
    }
}

await CLI.main()