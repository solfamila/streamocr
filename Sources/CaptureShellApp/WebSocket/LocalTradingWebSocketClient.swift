import Foundation

protocol TradingMessageSending: AnyObject {
    var reportsTransportOutcomes: Bool { get }
    func send(_ payload: String, event: String, completion: @escaping @Sendable (Result<Void, any Error>) -> Void)
    @discardableResult
    func waitForPendingMessages(timeout: TimeInterval) -> Bool
}

extension TradingMessageSending {
    var reportsTransportOutcomes: Bool { false }

    func send(_ payload: String, event: String) {
        send(payload, event: event) { _ in }
    }

    @discardableResult
    func waitForPendingMessages(timeout _: TimeInterval) -> Bool {
        true
    }
}

enum TradingWebSocketEndpoint {
    private static let defaultURLString = "ws://localhost:8080"
    private static let environmentKey = "TRADING_WS_URL"

    static func resolve() -> URL {
        if
            let overrideValue = ProcessInfo.processInfo.environment[environmentKey],
            let overrideURL = URL(string: overrideValue),
            let scheme = overrideURL.scheme?.lowercased(),
            (scheme == "ws" || scheme == "wss")
        {
            return overrideURL
        }

        guard let defaultURL = URL(string: defaultURLString) else {
            fatalError("Invalid default websocket URL: \(defaultURLString)")
        }

        return defaultURL
    }
}

final class LocalTradingWebSocketClient: NSObject, TradingMessageSending, @unchecked Sendable {
    private struct PendingSend {
        let payload: String
        let event: String
        let completion: @Sendable (Result<Void, any Error>) -> Void
    }

    private let endpointURL: URL
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        return URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
    }()

    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isConnecting = false
    private var isSending = false
    private var pendingSends: [PendingSend] = []

    init(endpointURL: URL = TradingWebSocketEndpoint.resolve()) {
        self.endpointURL = endpointURL
        super.init()
        connectIfNeeded()
    }

    var reportsTransportOutcomes: Bool { true }

    deinit {
        lock.lock()
        let activeTask = task
        let queuedSends = pendingSends
        task = nil
        isConnected = false
        isConnecting = false
        isSending = false
        pendingSends.removeAll()
        lock.unlock()

        activeTask?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()

        for pending in queuedSends {
            pending.completion(.failure(WebSocketSendError.cancelled))
        }
    }

    func send(_ payload: String, event: String, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        lock.lock()
        pendingSends.append(PendingSend(payload: payload, event: event, completion: completion))
        lock.unlock()

        connectIfNeeded()
        flushPendingSendsIfPossible()
    }

    @discardableResult
    func waitForPendingMessages(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if isIdle {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return isIdle
    }

    private var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSends.isEmpty && !isSending && !isConnecting
    }

    private var hasPendingSends: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pendingSends.isEmpty
    }

    private func connectIfNeeded() {
        let taskToStart: URLSessionWebSocketTask?
        lock.lock()
        if task == nil, !isConnecting {
            let createdTask = session.webSocketTask(with: endpointURL)
            task = createdTask
            isConnecting = true
            taskToStart = createdTask
        } else {
            taskToStart = nil
        }
        lock.unlock()

        guard let taskToStart else {
            return
        }

        print("[ws] connecting url=\(endpointURL.absoluteString)")
        taskToStart.resume()
        receiveNext(on: taskToStart)
    }

    private func flushPendingSendsIfPossible() {
        let nextSend: (task: URLSessionWebSocketTask, pending: PendingSend)?
        lock.lock()
        if
            isConnected,
            let task,
            !isSending,
            let pending = pendingSends.first
        {
            isSending = true
            pendingSends.removeFirst()
            nextSend = (task, pending)
        } else {
            nextSend = nil
        }
        lock.unlock()

        guard let nextSend else {
            return
        }

        nextSend.task.send(.string(nextSend.pending.payload)) { error in
            if let error {
                self.handleTransportError(task: nextSend.task, error: error)
                print("[ws] send_failed event=\(nextSend.pending.event) error=\(error.localizedDescription)")
                nextSend.pending.completion(.failure(error))
                self.lock.lock()
                self.isSending = false
                self.lock.unlock()
                if self.hasPendingSends {
                    self.connectIfNeeded()
                    self.flushPendingSendsIfPossible()
                }
                return
            }

            print("[ws] sent event=\(nextSend.pending.event) payload=\(nextSend.pending.payload)")
            nextSend.pending.completion(.success(()))
            self.lock.lock()
            self.isSending = false
            self.lock.unlock()
            self.flushPendingSendsIfPossible()
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(message):
                switch message {
                case let .string(text):
                    print("[ws] received text=\(text)")
                case let .data(data):
                    print("[ws] received bytes=\(data.count)")
                @unknown default:
                    print("[ws] received message of unknown type")
                }

                receiveNext(on: task)
            case let .failure(error):
                handleTransportError(task: task, error: error)
                print("[ws] receive_failed error=\(error.localizedDescription)")
            }
        }
    }

    private func handleTransportError(task: URLSessionWebSocketTask, error: Error) {
        let shouldClearState: Bool
        lock.lock()
        if self.task === task {
            self.task = nil
            isConnected = false
            isConnecting = false
            shouldClearState = true
        } else {
            shouldClearState = false
        }
        lock.unlock()

        if shouldClearState {
            print("[ws] disconnected error=\(error.localizedDescription)")
        }

        if hasPendingSends {
            connectIfNeeded()
        }
    }
}

private enum WebSocketSendError: LocalizedError {
    case notConnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "WebSocket is not connected."
        case .cancelled:
            "WebSocket sender was cancelled before pending messages were delivered."
        }
    }
}

extension LocalTradingWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        guard self.task === webSocketTask else {
            lock.unlock()
            return
        }
        isConnected = true
        isConnecting = false
        lock.unlock()

        print("[ws] connected")
        flushPendingSendsIfPossible()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        guard self.task === webSocketTask else {
            lock.unlock()
            return
        }
        task = nil
        isConnected = false
        isConnecting = false
        lock.unlock()

        let reasonText: String
        if let reason, !reason.isEmpty {
            reasonText = String(data: reason, encoding: .utf8) ?? "<binary>"
        } else {
            reasonText = "<none>"
        }

        print("[ws] disconnected close_code=\(closeCode.rawValue) reason=\(reasonText)")
        if hasPendingSends {
            connectIfNeeded()
        }
    }
}
