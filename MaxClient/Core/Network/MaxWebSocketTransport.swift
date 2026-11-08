import Foundation

/// JSON-транспорт: `wss://ws-api.oneme.ru/websocket`, `ver = 11`.
///
/// Тот же wire-протокол, что у web.max.ru: текстовые фреймы с полями
/// `{ver, cmd, seq, opcode, payload}`. Проще для отладки, не требует
/// собственной реализации бинарного кадра — поэтому это транспорт по умолчанию.
public final class MaxWebSocketTransport: MaxTransporting, @unchecked Sendable {
    public var onEvent: ((MaxClientEvent) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let url: URL
    private let origin: String
    private let pump = MaxFramePump()
    private let lock = NSLock()

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var didNotifyDisconnect = false
    /// Растёт при каждом успешном рукопожатии.
    private var generation = 0

    public init(url: URL = URL(string: MaxProtocol.wsURL)!,
                origin: String = "https://web.max.ru") {
        self.url = url
        self.origin = origin
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = MaxProtocol.requestTimeout
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: MaxTransporting

    public func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = MaxProtocol.requestTimeout

        // reset() обнуляет счётчик seq, поэтому до него не должно быть
        // отправленных кадров: иначе ответы придут с уже занятыми номерами.
        pump.reset()

        let task = session.webSocketTask(with: request)
        lock.lock()
        self.task = task
        isOpen = true
        didNotifyDisconnect = false
        lock.unlock()

        task.resume()
        receiveLoop(task)

        // Ждём подтверждения, что рукопожатие реально завершилось.
        // Без этого «соединение установлено» означало лишь «запрос
        // отправлен»: первый же INIT уходил в ещё не поднятый сокет.
        do {
            try await ping(task)
        } catch {
            // Не зовём handleDisconnect: он оповещает подписчиков о
            // разрыве, хотя сессии ещё нет. Достаточно вернуть состояние
            // в «закрыто» и отдать ошибку вызывающему.
            lock.lock()
            isOpen = false
            self.task = nil
            lock.unlock()
            task.cancel(with: .goingAway, reason: nil)
            pump.reset()
            throw MaxTransportError.connectionFailed(
                "Не удалось открыть WebSocket: \(error.localizedDescription)")
        }

        // Рукопожатие прошло: соединение сменилось, серверная сессия
        // пустая — вызывающая сторона обязана повторить INIT.
        lock.lock()
        generation += 1
        lock.unlock()
    }

    public func ensureConnected() async throws {
        lock.lock()
        let alreadyOpen = isOpen && task != nil
        lock.unlock()
        if alreadyOpen { return }
        try await connect()
    }

    /// WS-ping завершается только после рукопожатия — это единственный
    /// публичный способ дождаться готовности. В протокол MAX ping-кадр
    /// не попадает, поэтому серверу ничего лишнего не уходит.
    ///
    /// Ограничен по времени: если сервер молча не завершает рукопожатие,
    /// колбэк может не вызваться вообще, и без таймаута вход завис бы
    /// навсегда вместо внятной ошибки.
    private func ping(_ task: URLSessionWebSocketTask) async throws {
        // Результат забираем через @Sendable-обёртку: отмена «проигравшей»
        // задачи не должна превращать успех в ошибку, поэтому её исход
        // просто игнорируется, а не пробрасывается наружу.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = PingBox(continuation: continuation, timeout: MaxProtocol.requestTimeout)
            task.sendPing { error in
                box.finish(error.map { MaxTransportError.connectionFailed($0.localizedDescription) })
            }
            box.scheduleTimeout()
        }
    }

    public func send(frame: MaxFrame) async throws {
        guard isOpen, let task else { throw MaxTransportError.notConnected }
        let data = try frame.jsonData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw MaxTransportError.decode("frame is not valid UTF-8")
        }
        try await task.send(.string(text))
    }

    public func request(_ frame: MaxFrame, timeout: TimeInterval) async throws -> MaxFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MaxFrame, Error>) in
            pump.registerAwaiting(frame.sequence, continuation: continuation)
            Task {
                do {
                    try await self.send(frame: frame)
                } catch {
                    self.pump.failing(frame.sequence, error: error)
                }
            }
            pump.failLater(seq: frame.sequence,
                           after: timeout,
                           error: MaxTransportError.timedOut(opcode: frame.opcode))
        }
    }

    public func nextSeq() -> Int {
        pump.nextSeq()
    }

    public var connectionGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public func disconnect() {
        lock.lock()
        let task = self.task
        self.task = nil
        isOpen = false
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        pump.failAll(MaxTransportError.closed(nil))
    }

    // MARK: Receive

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                // isOpen читаем под замком: его меняет handleDisconnect
                // из другого потока, и без синхронизации цикл мог
                // остановиться навсегда после гонки.
                self.lock.lock()
                let stillOpen = self.isOpen
                self.lock.unlock()
                if stillOpen { self.receiveLoop(task) }
            case .failure(let error):
                self.handleDisconnect(error)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }

        guard let frame = try? MaxFrame(jsonData: data) else { return }

        switch frame.command {
        case MaxFrame.Command.response.rawValue:
            pump.completing(frame.sequence, frame: frame)
        case MaxFrame.Command.error.rawValue:
            let code = frame.payload["error"]?.string
            let text = frame.payload["message"]?.string ?? frame.payload["localizedMessage"]?.string
            if code == "auth.session.expired" || code == "auth.token.invalid" {
                pump.failing(frame.sequence, error: MaxTransportError.unauthorized)
            } else {
                pump.failing(frame.sequence,
                             error: MaxTransportError.server(opcode: frame.opcode, code: code, message: text))
            }
        default:
            let event = MaxEventMapper.map(frame: frame)
            if case .ping = event {
                let seq = pump.nextSeq()
                Task { try? await self.send(frame: MaxFrame(command: 0,
                                                            sequence: seq,
                                                            opcode: MaxOpcode.ping.rawValue,
                                                            payload: MPValue(["interactive": .bool(true)]))) }
            }
            onEvent?(event)
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
}

/// Однократный мост «колбэк sendPing → async»: кто первым завершит
/// (успех, ошибка или таймаут), тот и возобновляет ожидание. Повторные
/// вызовы игнорируются, иначе повторный resume уронил бы приложение.
private final class PingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let timeout: TimeInterval

    init(continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) {
        self.continuation = continuation
        self.timeout = timeout
    }

    func finish(_ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    func scheduleTimeout() {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.finish(MaxTransportError.connectionFailed("сервер не подтвердил соединение"))
        }
    }
}
