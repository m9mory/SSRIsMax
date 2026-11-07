import Foundation

/// Транспорт поверх TCP/TLS к `api.oneme.ru:443` — MessagePack, `ver = 10`.
///
/// Кадр: 10-байтовый big-endian заголовок
/// `(ver:u8, cmd:u8, seq:u16, opcode:u16, length:u32)` + MessagePack-массив
/// `[ver, cmd, seq, opcode, payload]`. Часть ответов сервера начинается
/// с «leading ints» перед массивом — код их пропускает.
///
/// Этот транспорт ближе всего к официальным мобильным клиентам.
/// По умолчанию клиент использует WebSocket (JSON), TCP включается
/// в настройках приложения.
public final class MaxTCPTransport: MaxTransporting, @unchecked Sendable {
    public var onEvent: ((MaxClientEvent) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let host: String
    private let port: UInt16
    private let pump = MaxFramePump()
    private let lock = NSLock()

    private var session: URLSession!
    private var socket: URLSessionStreamTask?
    private var buffer = Data()
    private var isOpen = false
    private var didNotifyDisconnect = false

    public init(host: String = MaxProtocol.tcpHost, port: UInt16 = MaxProtocol.tcpPort) {
        self.host = host
        self.port = port
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: MaxTransporting

    public func connect() async throws {
        let task = session.streamTask(withHostName: host, port: Int(port))
        lock.lock()
        socket = task
        buffer.removeAll()
        isOpen = true
        didNotifyDisconnect = false
        lock.unlock()
        pump.reset()

        // TLS поверх соединения (api.oneme.ru принимает только TLS).
        task.startSecureConnection()

        // Ждём установки TLS: пробный неблокирующий read завершится,
        // когда handshake пройдёт, либо вернёт ошибку.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.readData(ofMinLength: 1, maxLength: 1, timeout: 15) { _, _, error in
                if let error {
                    continuation.resume(throwing: MaxTransportError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        task.resume()
        scheduleRead()
    }

    public func send(frame: MaxFrame) async throws {
        guard isOpen, let socket else { throw MaxTransportError.notConnected }
        let packet = Self.pack(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.write(packet, timeout: 30) { error in
                if let error {
                    continuation.resume(throwing: MaxTransportError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func request(_ frame: MaxFrame, timeout: TimeInterval) async throws -> MaxFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MaxFrame, Error>) in
            pump.registerAwaiting(frame.sequence % 256, continuation: continuation)
            Task {
                do {
                    try await self.send(frame: frame)
                } catch {
                    self.pump.failing(frame.sequence % 256, error: error)
                }
            }
            pump.failLater(seq: frame.sequence % 256,
                           after: timeout,
                           error: MaxTransportError.timedOut(opcode: frame.opcode))
        }
    }

    public func disconnect() {
        lock.lock()
        let task = socket
        socket = nil
        isOpen = false
        lock.unlock()
        task?.cancel()
        pump.failAll(MaxTransportError.closed(nil))
    }

    // MARK: Приём

    private func scheduleRead() {
        guard let socket else { return }
        socket.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: 300) { [weak self] data, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                self.lock.unlock()
                self.drainFrames()
            }
            if let error {
                self.handleDisconnect(error)
                return
            }
            if self.isOpen { self.scheduleRead() }
        }
    }

    private func drainFrames() {
        while true {
            lock.lock()
            guard buffer.count >= 10 else { lock.unlock(); return }
            let bytes = [UInt8](buffer.prefix(10))
            let version = Int(bytes[0])
            let command = Int(bytes[1])
            let sequence = Int(bytes[2]) << 8 | Int(bytes[3])
            let opcode = Int32(bytes[4]) << 8 | Int32(bytes[5])
            let length = Int(bytes[6]) << 24 | Int(bytes[7]) << 16 | Int(bytes[8]) << 8 | Int(bytes[9])
            guard length >= 0, buffer.count >= 10 + length else { lock.unlock(); return }
            let body = buffer.subdata(in: 10..<(10 + length))
            buffer.removeFirst(10 + length)
            lock.unlock()

            guard let payload = try? Self.decodePayload(body) else { continue }
            let frame = MaxFrame(version: version,
                                 command: command,
                                 sequence: sequence,
                                 opcode: opcode,
                                 payload: payload)

            switch frame.command {
            case MaxFrame.Command.response.rawValue:
                pump.completing(sequence % 256, frame: frame)
            case MaxFrame.Command.error.rawValue:
                let code = frame.payload["error"]?.string
                let message = frame.payload["message"]?.string
                pump.failing(sequence % 256,
                             error: code == "auth.session.expired"
                             ? MaxTransportError.unauthorized
                             : MaxTransportError.server(opcode: opcode, code: code, message: message))
            default:
                let event = MaxEventMapper.map(frame: frame)
                if case .ping = event {
                    let seq = pump.nextSeq()
                    Task { try? await self.send(frame: MaxFrame(version: MaxProtocol.binaryVersion,
                                                                command: 0,
                                                                sequence: seq,
                                                                opcode: MaxOpcode.ping.rawValue,
                                                                payload: ["interactive": .bool(true)])) }
                }
                onEvent?(event)
            }
        }
    }

    private func handleDisconnect(_ error: Error?) {
        lock.lock()
        guard !didNotifyDisconnect else { lock.unlock(); return }
        didNotifyDisconnect = true
        isOpen = false
        lock.unlock()
        pump.failAll(MaxTransportError.closed(error?.localizedDescription))
        onDisconnect?(error)
    }

    // MARK: Кадры

    static func pack(_ frame: MaxFrame) -> Data {
        var binary = frame
        binary.version = MaxProtocol.binaryVersion
        binary.sequence = binary.sequence % 256

        let body = binary.binaryData()
        let length = UInt32(body.count)
        var packet = Data([
            UInt8(binary.version & 0xFF),
            UInt8(binary.command & 0xFF),
            UInt8((binary.sequence >> 8) & 0xFF),
            UInt8(binary.sequence & 0xFF),
            UInt8((Int(binary.opcode) >> 8) & 0xFF),
            UInt8(Int(binary.opcode) & 0xFF),
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        packet.append(body)
        return packet
    }

    /// Сервер иногда добавляет 1–2 leading int (fixedint) перед массивом.
    static func decodePayload(_ body: Data) throws -> MPValue {
        let bytes = [UInt8](body)
        var start = 0
        while start < min(2, bytes.count), bytes[start] <= 0x7f {
            start += 1
        }
        let values = try MPDecoder.decodeAll(body.subdata(in: start..<bytes.count))
        if values.count == 5 {
            return .array(values)
        }
        let full = try MPDecoder.decodeAll(body)
        guard let first = full.first else { throw MaxTransportError.decode("empty payload") }
        return first
    }
}
