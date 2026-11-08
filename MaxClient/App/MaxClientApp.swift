import SwiftUI

@main
struct MaxClientApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var session: Session

    init() {
        let settings = SettingsStore()
        let store = SettingsStore.makeKeychain()

        let session: Session
        do {
            let db = try DatabaseManager.makeQueue()
            session = Session(store: store, settings: settings, db: db)
        } catch {
            // База — обязательная часть клиента. Если файл не открывается
            // (место, повреждение), показываем диалог, а не падаем молча.
            assertionFailure("Не удалось открыть базу данных: \(error)")
            // Резерв — отдельный файл во временной папке. DatabaseQueue()
            // без аргументов в GRDB не существует, а try! убивал бы
            // приложение вместо мягкой деградации. Если не откроется и
            // этот, роняем осознанно: без базы клиент нерабочий.
            guard let temporary = try? DatabaseManager.makeQueue(url: DatabaseManager.temporaryURL()) else {
                fatalError("Не удалось открыть резервную базу данных: \(error)")
            }
            session = Session(store: store, settings: settings, db: temporary)
        }

        _settings = StateObject(wrappedValue: settings)
        _session = StateObject(wrappedValue: session)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(settings)
                .preferredColorScheme(preferredScheme)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch settings.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
