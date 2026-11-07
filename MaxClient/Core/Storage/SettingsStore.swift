import Foundation
import Combine
import Security

/// Простое хранилище настроек приложения.
public struct AppSettings: Equatable, Sendable {
    public enum TransportMode: String, Sendable, CaseIterable, Identifiable {
        case webSocket
        case tcp

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .webSocket: return "WebSocket (JSON)"
            case .tcp: return "TCP (MessagePack)"
            }
        }
    }

    public var transport: TransportMode
    public var theme: String
    public var sendReadReceipts: Bool

    public init(transport: TransportMode = .webSocket,
                theme: String = "system",
                sendReadReceipts: Bool = true) {
        self.transport = transport
        self.theme = theme
        self.sendReadReceipts = sendReadReceipts
    }
}

public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private let prefix = "max.settings."

    @Published public var settings: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = AppSettings(
            transport: AppSettings.TransportMode(rawValue: defaults.string(forKey: prefix + "transport") ?? "") ?? .webSocket,
            theme: defaults.string(forKey: prefix + "theme") ?? "system",
            sendReadReceipts: defaults.object(forKey: prefix + "readReceipts") as? Bool ?? true
        )
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        defaults.set(copy.transport.rawValue, forKey: prefix + "transport")
        defaults.set(copy.theme, forKey: prefix + "theme")
        defaults.set(copy.sendReadReceipts, forKey: prefix + "readReceipts")
    }

    public static func makeKeychain() -> KeychainCredentialStore {
        KeychainCredentialStore()
    }
}
