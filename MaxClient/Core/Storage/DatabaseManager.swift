import Foundation
import GRDB

/// Локальная база: чаты, сообщения, пользователи.
public final class DatabaseManager {
    public static func makeURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        return directory.appendingPathComponent("max-client.sqlite", isDirectory: false)
    }

    /// Резервный путь на случай, если основной файл базы не открывается
    /// (нет места, повреждение): приложение сможет показать интерфейс
    /// и дать пользователю выйти из аккаунта.
    public static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("max-client-recovery.sqlite")
    }

    public static func makeQueue(url: URL? = nil) throws -> DatabaseQueue {
        let path = try url ?? makeURL()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        try migrator.migrate(queue)
        return queue
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "user") { t in
                t.column("id", .integer).primaryKey()
                t.column("firstName", .text)
                t.column("lastName", .text)
                t.column("fullName", .text).notNull().defaults(to: "")
                t.column("phoneNumber", .text)
                t.column("about", .text)
                t.column("avatarURL", .text)
                t.column("isBot", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "chat") { t in
                t.column("id", .integer).primaryKey()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("avatarURL", .text)
                t.column("status", .text).notNull().defaults(to: "ACTIVE")
                t.column("lastEventTime", .integer).notNull().defaults(to: 0).indexed()
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("ownerID", .integer).notNull().defaults(to: 0)
                t.column("participantsCount", .integer).notNull().defaults(to: 0)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("descriptionText", .text)
                t.column("participantsJSON", .text)
                t.column("adminsJSON", .text)
            }

            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("chatId", .integer).notNull().indexed()
                t.column("senderId", .integer)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("timestamp", .integer).notNull().indexed()
                t.column("status", .text).notNull().defaults(to: "sent")
                t.column("cid", .integer)
                t.column("elementsJSON", .text)
                t.column("attachesJSON", .text)
                t.column("reactionsJSON", .text)
            }

            // FTS5 для поиска по тексту сообщений + триггеры синхронизации.
            try db.create(virtualTable: "message_search", using: FTS5()) { t in
                t.column("text")
                t.column("chatId", .text)
            }
            try db.execute(sql: """
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                  INSERT INTO message_search(text, chatId) VALUES (new.text, new.chatId);
                END;
                CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                  INSERT INTO message_search(message_search, text, chatId)
                    VALUES ('delete', old.text, old.chatId);
                END;
                CREATE TRIGGER message_au AFTER UPDATE ON message BEGIN
                  INSERT INTO message_search(message_search, text, chatId)
                    VALUES ('delete', old.text, old.chatId);
                  INSERT INTO message_search(text, chatId) VALUES (new.text, new.chatId);
                END;
                """)
        }

        migrator.registerMigration("v2-subscription") { db in
            try db.create(table: "subscription") { t in
                t.column("chatId", .integer).primaryKey()
                t.column("isSubscribed", .boolean).notNull().defaults(to: true)
            }
        }

        return migrator
    }
}
