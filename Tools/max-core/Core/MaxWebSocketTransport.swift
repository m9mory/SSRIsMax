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

        let task = session.webSocketTask(with: request)
        self.task = task
        self.isOpen = true
        self.didNotifyDisconnect = false
        self.pump.reset()
        task.resume()
        receiveLoop(task)
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
                if self.isOpen { self.receiveLoop(task) }
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
