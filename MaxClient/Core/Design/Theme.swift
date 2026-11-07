import SwiftUI

/// Дизайн-система клиента.
///
/// Взят фирменный синий MAX как основа, остальное — системные материалы
/// iOS, чтобы тёмная тема работала сама собой.
public enum Theme {
    public static let brand = Color(red: 0.12, green: 0.47, blue: 0.97)          // #1F78F7
    public static let brandGradientStart = Color(red: 0.10, green: 0.42, blue: 0.98)
    public static let brandGradientEnd = Color(red: 0.35, green: 0.22, blue: 0.92)

    public static let outgoingBubble = brand
    public static let incomingBubble = Color(uiColor: .secondarySystemBackground)
    public static let chatBackground = Color(uiColor: .systemGroupedBackground)
    public static let separator = Color(uiColor: .separator)

    public static func avatarColors(for id: MaxUserID) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.98, green: 0.55, blue: 0.32), Color(red: 0.90, green: 0.32, blue: 0.35)],
            [Color(red: 0.26, green: 0.72, blue: 0.68), Color(red: 0.12, green: 0.48, blue: 0.66)],
            [Color(red: 0.55, green: 0.45, blue: 0.92), Color(red: 0.32, green: 0.28, blue: 0.72)],
            [Color(red: 0.96, green: 0.66, blue: 0.26), Color(red: 0.88, green: 0.45, blue: 0.16)],
            [Color(red: 0.42, green: 0.66, blue: 0.98), Color(red: 0.22, green: 0.42, blue: 0.86)]
        ]
        let index = Int(abs(id) % Int64(palettes.count))
        return palettes[index]
    }
}

/// Аватар: картинка из сети или инициалы на градиенте.
struct AvatarView: View {
    var url: URL?
    var title: String
    var id: MaxUserID
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
    }

    private var initials: some View {
        ZStack {
            LinearGradient(colors: Theme.avatarColors(for: id), startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initialsText)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initialsText: String {
        let parts = title.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// Строка «последнее сообщение» / время.
enum ChatFormatter {
    static func time(_ millis: UnixMillis) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "d MMM"
        } else {
            formatter.dateFormat = "dd.MM.yy"
        }
        return formatter.string(from: date)
    }

    static func relative(_ millis: UnixMillis) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func preview(_ message: MaxMessage?) -> String {
        guard let message else { return "Нет сообщений" }
        if let attachment = message.attachments.first(where: { $0.kind != .keyboard }) {
            switch attachment.kind {
            case .photo: return "📷 Фотография"
            case .video: return "🎬 Видео"
            case .file: return "📎 " + (attachment.fileName ?? "Файл")
            case .audio: return "🎤 Голосовое сообщение"
            case .sticker: return "Стикер"
            case .call: return "📞 Звонок"
            default: break
            }
        }
        return message.text.isEmpty ? "Сообщение" : message.text
    }
}
