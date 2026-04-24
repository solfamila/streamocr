import Foundation

enum TradingMessageSendOutcome: Equatable, Sendable {
    case submitted
    case intentionallyIgnored(reason: String)

    var commitsTriggerState: Bool {
        switch self {
        case .submitted, .intentionallyIgnored:
            true
        }
    }

    var resultLabel: String {
        switch self {
        case .submitted:
            "submitted"
        case .intentionallyIgnored:
            "ignored"
        }
    }
}

enum TradingMessageSendError: LocalizedError, Equatable, Sendable {
    case retryableRejection(reason: String)
    case cancelled(reason: String)

    var errorDescription: String? {
        switch self {
        case let .retryableRejection(reason), let .cancelled(reason):
            reason
        }
    }
}

protocol TradingMessageSending: AnyObject {
    var reportsTransportOutcomes: Bool { get }
    func send(
        _ payload: String,
        event: String,
        completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
    )
    @discardableResult
    func waitForPendingMessages(timeout: TimeInterval) -> Bool
    func cancelPendingMessages(reason: String)
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

    func cancelPendingMessages(reason _: String) {}
}

final class DiscardingTradingMessageSender: TradingMessageSending, @unchecked Sendable {
    func send(
        _ payload: String,
        event _: String,
        completion: @escaping @Sendable (Result<TradingMessageSendOutcome, any Error>) -> Void
    ) {
        _ = payload
        completion(.success(.submitted))
    }
}
