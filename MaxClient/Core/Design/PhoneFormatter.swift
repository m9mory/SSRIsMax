import Foundation

/// Преобразование номеров для MAX.
///
/// Сервер ждёт номер в формате E.164: `+7XXXXXXXXXX`. Пользователи
/// вводят по-разному: `89991234567`, `79991234567`, `+7 (999) 123-45-67`.
public enum PhoneFormatter {
    public static func normalize(_ raw: String) -> String? {
        var digits = raw.filter(\.isNumber)
        if digits.count == 11 && digits.hasPrefix("8") {
            digits = "7" + digits.dropFirst()
        }
        if digits.count == 10 {
            digits = "7" + digits
        }
        guard digits.count == 11, digits.hasPrefix("7") else { return nil }
        return "+" + digits
    }

    /// Маска для поля ввода: `+7 999 123-45-67`.
    public static func mask(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
        if !digits.hasPrefix("7") { digits = "7" + digits }
        digits = String(digits.prefix(11))
        guard !digits.isEmpty else { return "+7 " }

        let rest = Array(digits.dropFirst())
        var result = "+7 "
        let layout: [(prefix: Int, count: Int, separator: String)] = [
            (0, 3, " "),
            (3, 3, "-"),
            (6, 2, "-"),
            (8, 2, "")
        ]
        for group in layout {
            guard rest.count > group.prefix else { break }
            let slice = rest[group.prefix..<min(rest.count, group.prefix + group.count)]
            result += String(slice)
            if rest.count > group.prefix + group.count { result += group.separator }
        }
        return result
    }

    public static func display(_ phone: String?) -> String {
        guard let phone else { return "" }
        return mask(phone)
    }
}