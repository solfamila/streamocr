import Foundation

struct SymbolNormalizationAnalysis: Equatable, Sendable {
    let normalized: String
    let droppedAlphanumericCount: Int
    let droppedDigitCount: Int

    var shouldRejectOCRCandidate: Bool {
        droppedAlphanumericCount > 0
    }
}

enum TradingWebSocketContract {
    static let buyMessage = #"{"action":"BUY"}"#

    static func normalizeSymbol(_ symbol: String) -> String {
        normalizedOCRSymbol(symbol) ?? ""
    }

    static func normalizedOCRSymbol(_ symbol: String) -> String? {
        let analysis = analyzeSymbol(symbol)
        guard !analysis.shouldRejectOCRCandidate, !analysis.normalized.isEmpty else {
            return nil
        }
        return analysis.normalized
    }

    static func sanitizeTransportSymbol(_ symbol: String) -> String {
        symbol.uppercased().filter(\.isLetter)
    }

    static func analyzeSymbol(_ symbol: String) -> SymbolNormalizationAnalysis {
        var normalized = ""
        var droppedAlphanumericCount = 0
        var droppedDigitCount = 0

        for character in symbol.uppercased() {
            if character.isLetter {
                normalized.append(character)
                continue
            }

            if character.isNumber {
                droppedDigitCount += 1
                droppedAlphanumericCount += 1
                continue
            }

            if character.isASCII, String(character).rangeOfCharacter(from: .alphanumerics) != nil {
                droppedAlphanumericCount += 1
            }
        }

        return SymbolNormalizationAnalysis(
            normalized: normalized,
            droppedAlphanumericCount: droppedAlphanumericCount,
            droppedDigitCount: droppedDigitCount
        )
    }

    static func subscribeMessage(symbol: String) -> String {
        let normalized = sanitizeTransportSymbol(symbol)
        return #"{"subscribe":"\#(normalized)"}"#
    }
}
