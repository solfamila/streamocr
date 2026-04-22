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

final class DiscardingTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    func send(
        _ payload: String,
        event _: String,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        _ = payload
        completion(.success(()))
    }
}
