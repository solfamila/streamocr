import Foundation

enum TradingWebSocketContract {
    static let buyMessage = #"{"action":"BUY"}"#

    static func subscribeMessage(symbol: String) -> String {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return #"{"subscribe":"\#(normalized)"}"#
    }
}
