import Foundation

enum TradingWebSocketContract {
    static let buyMessage = #"{"action":"BUY"}"#

    static func normalizeSymbol(_ symbol: String) -> String {
        symbol.uppercased().filter(\.isLetter)
    }

    static func subscribeMessage(symbol: String) -> String {
        let normalized = normalizeSymbol(symbol)
        return #"{"subscribe":"\#(normalized)"}"#
    }
}
