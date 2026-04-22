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
        let id: Int
        let payload: String
        let event: String
        let completion: @Sendable (Result<Void, any Error>) -> Void
    }

    private let endpointURL: URL
    private let lock = NSLock()

    private var session: URLSession?

    private func makeSession() -> URLSession {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        return URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
    }

    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isConnecting = false
    private var isSending = false
    private var currentSend: PendingSend?
    private var pendingSends: [PendingSend] = []
    private var nextSendID = 0

    init(endpointURL: URL = TradingWebSocketEndpoint.resolve(), connectOnInit: Bool = true) {
        self.endpointURL = endpointURL
        super.init()
        if connectOnInit {
            connectIfNeeded()
        }
    }

    var reportsTransportOutcomes: Bool { true }

    deinit {
        let cancelledSends = failOutstandingSends(with: WebSocketSendError.cancelled, cancelActiveTask: true)
        session?.invalidateAndCancel()

        for pending in cancelledSends {
            pending.completion(.failure(WebSocketSendError.cancelled))
        }
    }

    func send(_ payload: String, event: String, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        lock.lock()
        pendingSends.append(makePendingSend(payload: payload, event: event, completion: completion))
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

        if isIdle {
            return true
        }

        let timedOutSends = failOutstandingSends(with: WebSocketSendError.timedOut, cancelActiveTask: true)
        for pending in timedOutSends {
            pending.completion(.failure(WebSocketSendError.timedOut))
        }
        return false
    }

    private var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingSends.isEmpty && currentSend == nil && !isSending && !isConnecting
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
            let session = self.session ?? makeSession()
            self.session = session
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
            currentSend = pending
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
                guard let failedSend = self.finishCurrentSendIfMatching(id: nextSend.pending.id) else {
                    return
                }
                self.handleTransportError(task: nextSend.task, error: error)
                print("[ws] send_failed event=\(failedSend.event) error=\(error.localizedDescription)")
                failedSend.completion(.failure(error))
                if self.hasPendingSends {
                    self.connectIfNeeded()
                    self.flushPendingSendsIfPossible()
                }
                return
            }

            guard let sentSend = self.finishCurrentSendIfMatching(id: nextSend.pending.id) else {
                return
            }

            print("[ws] sent event=\(sentSend.event) payload=\(sentSend.payload)")
            sentSend.completion(.success(()))
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

    private func makePendingSend(
        payload: String,
        event: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) -> PendingSend {
        let pending = PendingSend(id: nextSendID, payload: payload, event: event, completion: completion)
        nextSendID += 1
        return pending
    }

    private func finishCurrentSendIfMatching(id: Int) -> PendingSend? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentSend, currentSend.id == id else {
            return nil
        }
        self.currentSend = nil
        isSending = false
        return currentSend
    }

    private func failOutstandingSends(with error: WebSocketSendError, cancelActiveTask: Bool) -> [PendingSend] {
        let activeTask: URLSessionWebSocketTask?
        let outstandingSends: [PendingSend]

        lock.lock()
        activeTask = cancelActiveTask ? task : nil
        outstandingSends = (currentSend.map { [$0] } ?? []) + pendingSends
        task = nil
        isConnected = false
        isConnecting = false
        isSending = false
        currentSend = nil
        pendingSends.removeAll()
        lock.unlock()

        if cancelActiveTask {
            activeTask?.cancel(with: .goingAway, reason: nil)
            if !outstandingSends.isEmpty {
                print("[ws] failing_outstanding_sends reason=\(error.localizedDescription)")
            }
        }

        return outstandingSends
    }

    func enqueuePendingSendForTesting(
        payload: String,
        event: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.lock()
        pendingSends.append(makePendingSend(payload: payload, event: event, completion: completion))
        lock.unlock()
    }

    func beginInFlightSendForTesting(
        payload: String,
        event: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        lock.lock()
        currentSend = makePendingSend(payload: payload, event: event, completion: completion)
        isSending = true
        lock.unlock()
    }
}

private enum WebSocketSendError: LocalizedError {
    case notConnected
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "WebSocket is not connected."
        case .cancelled:
            "WebSocket sender was cancelled before pending messages were delivered."
        case .timedOut:
            "WebSocket sender timed out before pending messages were delivered."
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
