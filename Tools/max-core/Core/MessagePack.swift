import Foundation

#if os(Linux) || os(Windows)
import FoundationNetworking
#endif

/// Минимальный MessagePack: кодирование и декодирование.
///
/// Нужен по нескольким причинам:
/// - MAX обслуживает WebSocket простым JSON, но часть клиентов (в том числе
///   официальные мобильные) общается по `api.oneme.ru` бинарным MessagePack
///   с 64-битными числами через extension-тип.
/// - Юнит-тесты ядра не тянут внешние пакеты, поэтому кодек написан руками.
public enum MPValue: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MPValue])
    case map([MPMapKey: MPValue])
    case ext(type: Int8, data: Data)
}

/// Ключи Map в MessagePack не обязаны быть строками, но на практике в MAX
/// это всегда строки. Чтобы не терять другие типы — обёртка.
public struct MPMapKey: Hashable, Sendable, CustomStringConvertible {
    public let value: MPValue

    public init(_ value: MPValue) {
        self.value = value
    }

    public init(_ string: String) {
        self.value = .string(string)
    }

    public init(_ int: Int64) {
        self.value = .int(int)
    }

    public var description: String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return String(b)
        case .double(let d): return String(d)
        default: return "\(value)"
        }
    }

    var stringValue: String? {
        if case .string(let s) = value { return s }
        return nil
    }
}

// MARK: - Decoding

public struct MPDecodeError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "MessagePack decode error at \(offset): \(reason)" }
}

public enum MPDecoder {
    public static func decodeAll(_ data: Data) throws -> [MPValue] {
        var decoder = Decoder(bytes: [UInt8](data))
        var values: [MPValue] = []
        while !decoder.isAtEnd {
            values.append(try decoder.decodeValue())
        }
        return values
    }

    public static func decode(_ data: Data) throws -> MPValue {
        var decoder = Decoder(bytes: [UInt8](data))
        let value = try decoder.decodeValue()
        return value
    }

    struct Decoder {
        let bytes: [UInt8]
        var offset: Int = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func need(_ n: Int) throws {
            guard offset + n <= bytes.count else {
                throw MPDecodeError(offset: offset, reason: "unexpected end of data (need \(n))")
            }
        }

        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func bigEndian<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            try need(size)
            var value: T = 0
            for i in 0..<size {
                value = (value << 8) | T(bytes[offset + i])
            }
            offset += size
            return value
        }

        mutating func rawBytes(_ count: Int) throws -> Data {
            try need(count)
            let slice = bytes[offset..<(offset + count)]
            offset += count
            return Data(slice)
        }

        mutating func decodeValue() throws -> MPValue {
            let prefix = try u8()
            switch prefix {
            case 0x00...0x7f: // positive fixint
                return .int(Int64(prefix))
            case 0xe0...0xff: // negative fixint
                return .int(Int64(Int8(bitPattern: prefix)))
            case 0x80...0x8f: // fixmap
                return try decodeMap(count: Int(prefix & 0x0f))
            case 0x90...0x9f: // fixarray
                return try decodeArray(count: Int(prefix & 0x0f))
            case 0xa0...0xbf: // fixstr
                return try decodeString(length: Int(prefix & 0x1f))
            case 0xc0:
                return .null
            case 0xc2:
                return .bool(false)
            case 0xc3:
                return .bool(true)
            case 0xc4: // bin 8
                let n = Int(try u8())
                return .binary(try rawBytes(n))
            case 0xc5: // bin 16
                let n = Int(try bigEndian(UInt16.self))
                return .binary(try rawBytes(n))
            case 0xc6: // bin 32
                let n = Int(try bigEndian(UInt32.self))
                return .binary(try rawBytes(n))
            case 0xc7, 0xc8, 0xc9: // ext 8/16/32
                let length: Int
                switch prefix {
                case 0xc7: length = Int(try u8())
                case 0xc8: length = Int(try bigEndian(UInt16.self))
                default: length = Int(try bigEndian(UInt32.self))
                }
                let type = Int8(bitPattern: try u8())
                let payload = try rawBytes(length)
                return .ext(type: type, data: payload)
            case 0xca:
                return .double(Double(Float(bitPattern: try bigEndian(UInt32.self))))
            case 0xcb:
                return .double(Double(bitPattern: try bigEndian(UInt64.self)))
            case 0xcc:
                return .int(Int64(try u8()))
            case 0xcd:
                return .int(Int64(try bigEndian(UInt16.self)))
            case 0xce:
                return .int(Int64(try bigEndian(UInt32.self)))
            case 0xcf:
                let raw = try bigEndian(UInt64.self)
                return .int(Int64(bitPattern: raw))
            case 0xd0:
                return .int(Int64(Int8(bitPattern: try u8())))
            case 0xd1:
                return .int(Int64(try bigEndian(Int16.self)))
            case 0xd2:
                return .int(Int64(try bigEndian(Int32.self)))
            case 0xd3:
                return .int(try bigEndian(Int64.self))
            case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8: // fixext 1/2/4/8/16
                let length = 1 << Int(prefix - 0xd4)
                let type = Int8(bitPattern: try u8())
                return .ext(type: type, data: try rawBytes(length))
            case 0xd9: // str 8
                return try decodeString(length: Int(try u8()))
            case 0xda: // str 16
                return try decodeString(length: Int(try bigEndian(UInt16.self)))
            case 0xdb: // str 32
                return try decodeString(length: Int(try bigEndian(UInt32.self)))
            case 0xdc: // array 16
                return try decodeArray(count: Int(try bigEndian(UInt16.self)))
            case 0xdd: // array 32
                return try decodeArray(count: Int(try bigEndian(UInt32.self)))
            case 0xde: // map 16
                return try decodeMap(count: Int(try bigEndian(UInt16.self)))
            case 0xdf: // map 32
                return try decodeMap(count: Int(try bigEndian(UInt32.self)))
            default:
                throw MPDecodeError(offset: offset - 1, reason: String(format: "unknown type byte 0x%02X", prefix))
            }
        }

        mutating func decodeString(length: Int) throws -> MPValue {
            let data = try rawBytes(length)
            guard let s = String(data: data, encoding: .utf8) else {
                // Невалидный UTF-8 — отдаём как бинарь, чтобы не терять данные.
                return .binary(data)
            }
            return .string(s)
        }

        mutating func decodeArray(count: Int) throws -> MPValue {
            var items: [MPValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try decodeValue())
            }
            return .array(items)
        }

        mutating func decodeMap(count: Int) throws -> MPValue {
            var map: [MPMapKey: MPValue] = [:]
            map.reserveCapacity(count)
            for _ in 0..<count {
                let key = try decodeValue()
                let value = try decodeValue()
                map[MPMapKey(key)] = value
            }
            return .map(map)
        }
    }
}

// MARK: - Encoding

public enum MPEncoder {
    public static func encode(_ value: MPValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: MPValue, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .int(let i):
            writeInt(i, into: &out)
        case .double(let d):
            out.append(0xcb)
            appendBigEndian(d.bitPattern, into: &out)
        case .string(let s):
            let bytes = Data(s.utf8)
            writeStrHeader(bytes.count, into: &out)
            out.append(bytes)
        case .binary(let data):
            writeBinHeader(data.count, into: &out)
            out.append(data)
        case .array(let items):
            writeArrayHeader(items.count, into: &out)
            for item in items { write(item, into: &out) }
        case .map(let map):
            writeMapHeader(map.count, into: &out)
            for (key, value) in map {
                write(key.value, into: &out)
                write(value, into: &out)
            }
        case .ext(let type, let data):
            writeExtHeader(data.count, into: &out)
            out.append(UInt8(bitPattern: type))
            out.append(data)
        }
    }

    private static func writeInt(_ value: Int64, into out: inout Data) {
        switch value {
        case 0...0x7f:
            out.append(UInt8(value))
        case -32...(-1):
            out.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int8.min)...Int64(Int8.max):
            out.append(0xd0)
            out.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int16.min)...Int64(Int16.max):
            out.append(0xd1)
            appendBigEndian(UInt16(bitPattern: Int16(value)), into: &out)
        case Int64(Int32.min)...Int64(Int32.max):
            out.append(0xd2)
            appendBigEndian(UInt32(bitPattern: Int32(value)), into: &out)
        case 0...Int64(UInt32.max):
            out.append(0xce)
            appendBigEndian(UInt32(value), into: &out)
        default:
            out.append(0xd3)
            appendBigEndian(UInt64(bitPattern: value), into: &out)
        }
    }

    private static func writeStrHeader(_ count: Int, into out: inout Data) {
        if count < 32 {
            out.append(0xa0 | UInt8(count))
        } else if count < 256 {
            out.append(0xd9)
            out.append(UInt8(count))
        } else if count < 65536 {
            out.append(0xda)
            appendBigEndian(UInt16(count), into: &out)
        } else {
            out.append(0xdb)
            appendBigEndian(UInt32(count), into: &out)
        }
    }

    private static func writeBinHeader(_ count: Int, into out: inout Data) {
        if count < 256 {
            out.append(0xc4)
            out.append(UInt8(count))
        } else if count < 65536 {
            out.append(0xc5)
            appendBigEndian(UInt16(count), into: &out)
        } else {
            out.append(0xc6)
            appendBigEndian(UInt32(count), into: &out)
        }
    }

    private static func writeArrayHeader(_ count: Int, into out: inout Data) {
        if count < 16 {
            out.append(0x90 | UInt8(count))
        } else if count < 65536 {
            out.append(0xdc)
            appendBigEndian(UInt16(count), into: &out)
        } else {
            out.append(0xdd)
            appendBigEndian(UInt32(count), into: &out)
        }
    }

    private static func writeMapHeader(_ count: Int, into out: inout Data) {
        if count < 16 {
            out.append(0x80 | UInt8(count))
        } else if count < 65536 {
            out.append(0xde)
            appendBigEndian(UInt16(count), into: &out)
        } else {
            out.append(0xdf)
            appendBigEndian(UInt32(count), into: &out)
        }
    }

    private static func writeExtHeader(_ count: Int, into out: inout Data) {
        switch count {
        case 1: out.append(0xd4)
        case 2: out.append(0xd5)
        case 4: out.append(0xd6)
        case 8: out.append(0xd7)
        case 16: out.append(0xd8)
        default:
            if count < 256 {
                out.append(0xc7)
                out.append(UInt8(count))
            } else if count < 65536 {
                out.append(0xc8)
                appendBigEndian(UInt16(count), into: &out)
            } else {
                out.append(0xc9)
                appendBigEndian(UInt32(count), into: &out)
            }
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, into out: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }
}

// MARK: - Удобства доступа

public extension MPValue {
    /// Разрешает писать `["chatId": .int(1)]` там, где ожидается `MPValue`.
    init(_ map: [String: MPValue]) {
        self = .map(map.reduce(into: [MPMapKey: MPValue]()) { $0[MPMapKey($1.key)] = $1.value })
    }

    /// Рекурсивная сборка из JSON-объекта (ответ сервера в JSON-транспорте).
    ///
    /// Числа проверяем на точность: `Double` не переживёт Int64-идентификаторы
    /// MAX, поэтому `NSNumber` разбираем через строковое представление.
    init(jsonObject any: Any) {
        switch any {
        case let value as MPValue:
            self = value
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let data as Data:
            self = .binary(data)
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = MPValue(number: number)
        case let array as [Any]:
            self = .array(array.map { MPValue(jsonObject: $0) })
        case let dictionary as [String: Any]:
            var map: [MPMapKey: MPValue] = [:]
            map.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                map[MPMapKey(key)] = MPValue(jsonObject: value)
            }
            self = .map(map)
        case let dictionary as [AnyHashable: Any]:
            var map: [MPMapKey: MPValue] = [:]
            for (key, value) in dictionary {
                map[MPMapKey(MPValue(jsonObject: key))] = MPValue(jsonObject: value)
            }
            self = .map(map)
        default:
            self = .string(String(describing: any))
        }
    }

    private init(number: NSNumber) {
        // Bool в JSON приходит как NSNumber, но с objCType "c" (CFBoolean).
        // CoreFoundation не берём: он не нужен и не всегда линкуется в SPM.
        let objCType = String(cString: number.objCType)
        if objCType == "c" || objCType == "B" {
            self = .bool(number.boolValue)
            return
        }
        if objCType == "f" || objCType == "d" {
            self = .double(number.doubleValue)
            return
        }
        if let exact = Int64(number.stringValue) {
            self = .int(exact)
            return
        }
        self = .double(number.doubleValue)
    }

    subscript(key: String) -> MPValue? {
        if case .map(let map) = self { return map[MPMapKey(key)] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        default: return nil
        }
    }

    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(exactly: d.rounded())
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        if let i = int64 { return i != 0 }
        return nil
    }

    var arrayItems: [MPValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var mapEntries: [MPMapKey: MPValue] {
        if case .map(let map) = self { return map }
        return [:]
    }

    var data: Data? {
        if case .binary(let d) = self { return d }
        if case .string(let s) = self { return Data(s.utf8) }
        return nil
    }

    /// Обратное преобразование для отладки и для JS-подобного API.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return d
        case .string(let s): return s
        case .binary(let d): return d
        case .array(let items): return items.map(\.foundation)
        case .map(let map): return map.reduce(into: [String: Any]()) { $0[String(describing: $1.key)] = $1.value.foundation }
        case .ext(let type, let data): return ["__extType": type, "__extData": data.base64EncodedString()] as [String: Any]
        }
    }
}
