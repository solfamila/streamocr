import Foundation

protocol TradingMessageSending: AnyObject {
    func send(_ payload: String, event: String)
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

    init(endpointURL: URL = TradingWebSocketEndpoint.resolve()) {
        self.endpointURL = endpointURL
        super.init()
        connectIfNeeded()
    }

    deinit {
        lock.lock()
        let activeTask = task
        task = nil
        isConnected = false
        isConnecting = false
        lock.unlock()

        activeTask?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func send(_ payload: String, event: String) {
        connectIfNeeded()

        let taskSnapshot: URLSessionWebSocketTask?
        let connected: Bool
        lock.lock()
        taskSnapshot = task
        connected = isConnected
        lock.unlock()

        guard connected, let taskSnapshot else {
            print("[ws] not connected; \(event) not sent")
            return
        }

        taskSnapshot.send(.string(payload)) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                handleTransportError(task: taskSnapshot, error: error)
                print("[ws] send_failed event=\(event) error=\(error.localizedDescription)")
                return
            }

            print("[ws] sent event=\(event) payload=\(payload)")
        }
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
    }
}
