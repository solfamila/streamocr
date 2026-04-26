import Foundation

enum TradingMessageContractError: Error, LocalizedError {
    case invalidSymbol(String)
    case invalidBuyPayload
    case invalidSellPayload

    var errorDescription: String? {
        switch self {
        case let .invalidSymbol(symbol):
            "Refusing to build subscribe payload from invalid symbol input: \(symbol)"
        case .invalidBuyPayload:
            "Refusing to use an invalid OCR buy payload."
        case .invalidSellPayload:
            "Refusing to use an invalid OCR sell payload."
        }
    }
}

struct SymbolNormalizationAnalysis: Equatable, Sendable {
    let normalized: String
    let droppedAlphanumericCount: Int
    let droppedDigitCount: Int

    var shouldRejectOCRCandidate: Bool {
        droppedAlphanumericCount > 0
    }
}

struct OCRBuyMessage: Equatable, Sendable {
    let ocrQuantity: Int?
}

struct OCRSellMessage: Equatable, Sendable {
    let ocrQuantity: Int?
    let previousOCRQuantity: Int?
}

enum TradingMessageContract {
    static func buyMessage(ocrQuantity: Int?) -> String {
        guard let ocrQuantity else {
            return #"{"action":"BUY"}"#
        }
        return #"{"action":"BUY","ocrQuantity":\#(ocrQuantity)}"#
    }

    static func sellMessage(ocrQuantity: Int?, previousOCRQuantity: Int?) -> String {
        var fields = [#""action":"SELL""#]
        if let ocrQuantity {
            fields.append(#""ocrQuantity":\#(ocrQuantity)"#)
        }
        if let previousOCRQuantity {
            fields.append(#""previousOCRQuantity":\#(previousOCRQuantity)"#)
        }
        return "{\(fields.joined(separator: ","))}"
    }

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

    static func analyzeSymbol(_ symbol: String) -> SymbolNormalizationAnalysis {
        var normalized = ""
        var droppedAlphanumericCount = 0
        var droppedDigitCount = 0

        for character in symbol.uppercased() {
            if let asciiLetter = asciiUppercaseLetter(character) {
                normalized.append(asciiLetter)
                continue
            }

            if isDigit(character) {
                droppedDigitCount += 1
                droppedAlphanumericCount += 1
                continue
            }

            if isNonASCIILetterOrDigit(character) {
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

    static func subscribeMessage(symbol: String) -> String? {
        guard let normalized = normalizedOCRSymbol(symbol) else {
            return nil
        }
        return #"{"subscribe":"\#(normalized)"}"#
    }

    static func parseBuyMessage(_ payload: String) throws -> OCRBuyMessage {
        guard let data = payload.data(using: .utf8) else {
            throw TradingMessageContractError.invalidBuyPayload
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TradingMessageContractError.invalidBuyPayload
        }

        guard object["action"] as? String == "BUY" else {
            throw TradingMessageContractError.invalidBuyPayload
        }

        let ocrQuantity: Int?
        if let rawQuantity = object["ocrQuantity"] {
            if let integerQuantity = rawQuantity as? Int {
                ocrQuantity = integerQuantity
            } else if let integer64Quantity = rawQuantity as? Int64 {
                ocrQuantity = Int(integer64Quantity)
            } else if let numberQuantity = rawQuantity as? NSNumber {
                ocrQuantity = numberQuantity.intValue
            } else {
                throw TradingMessageContractError.invalidBuyPayload
            }
        } else {
            ocrQuantity = nil
        }

        return OCRBuyMessage(ocrQuantity: ocrQuantity)
    }

    static func parseSellMessage(_ payload: String) throws -> OCRSellMessage {
        guard let data = payload.data(using: .utf8) else {
            throw TradingMessageContractError.invalidSellPayload
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TradingMessageContractError.invalidSellPayload
        }

        guard object["action"] as? String == "SELL" else {
            throw TradingMessageContractError.invalidSellPayload
        }

        return OCRSellMessage(
            ocrQuantity: try optionalIntegerField("ocrQuantity", in: object),
            previousOCRQuantity: try optionalIntegerField("previousOCRQuantity", in: object)
        )
    }

    private static func optionalIntegerField(_ key: String, in object: [String: Any]) throws -> Int? {
        guard let rawValue = object[key] else {
            return nil
        }

        if let integerValue = rawValue as? Int {
            return integerValue
        }

        if let integer64Value = rawValue as? Int64 {
            return Int(integer64Value)
        }

        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }

        throw TradingMessageContractError.invalidSellPayload
    }

    private static func asciiUppercaseLetter(_ character: Character) -> Character? {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first,
            scalar.isASCII,
            scalar.value >= 65,
            scalar.value <= 90
        else {
            return nil
        }
        return character
    }

    private static func isDigit(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func isNonASCIILetterOrDigit(_ character: Character) -> Bool {
        guard !character.isASCII else {
            return false
        }

        let characterString = String(character)
        return characterString.rangeOfCharacter(from: .letters) != nil
            || characterString.rangeOfCharacter(from: .decimalDigits) != nil
    }
}
