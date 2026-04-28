import Foundation

enum ManualCellIntegerPolicy {
    static func parseInteger(_ normalizedText: String) -> Int? {
        let trimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let compact = trimmed
            .uppercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else {
            return nil
        }

        var sign = ""
        var body = compact
        if let first = body.first, first == "+" || first == "-" {
            sign = String(first)
            body.removeFirst()
        }

        guard !body.isEmpty else {
            return nil
        }

        let characters = Array(body)
        let digitCount = characters.filter(\.isNumber).count
        let ambiguousCount = characters.count - digitCount

        guard digitCount > 0 else {
            return nil
        }

        // Allow a couple of OCR-confused glyphs when the token is otherwise numeric.
        guard ambiguousCount <= 2 else {
            return nil
        }

        var normalizedDigits = ""
        normalizedDigits.reserveCapacity(characters.count)

        for index in characters.indices {
            let character = characters[index]
            if character.isNumber {
                normalizedDigits.append(character)
                continue
            }

            guard
                let substituted = substituteAmbiguousDigit(character, index: index, characters: characters)
            else {
                return nil
            }

            normalizedDigits.append(substituted)
        }

        return Int(sign + normalizedDigits)
    }

    private static func substituteAmbiguousDigit(
        _ character: Character,
        index: Int,
        characters: [Character]
    ) -> Character? {
        let replacement: Character?
        switch character {
        case "A":
            replacement = "4"
        case "O", "Q", "D":
            replacement = "0"
        case "I", "L", "|":
            replacement = "1"
        case "S":
            replacement = "5"
        case "B":
            replacement = "8"
        case "Z":
            replacement = "2"
        default:
            replacement = nil
        }

        guard let replacement else {
            return nil
        }

        let previousIsDigit = index > 0 && characters[index - 1].isNumber
        let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
        guard previousIsDigit || nextIsDigit else {
            return nil
        }

        return replacement
    }
}

struct ManualCellTriggerEvaluation {
    let normalizedText: String
    let integerValue: Int?
    let openPositionPeakValue: Int?
    let isZeroOrEmpty: Bool
    let isDuplicate: Bool
    let isAwaitingConfirmation: Bool
    let confirmationProgress: Int
    let requiredConfirmationCount: Int
    let shouldTriggerBuy: Bool
    let shouldTriggerSell: Bool
    let shouldBeep: Bool
    let wasArmed: Bool
    let isArmedAfter: Bool
}

struct ManualSymbolTriggerEvaluation {
    let normalizedSymbol: String
    let isDuplicate: Bool
    let isChangeLocked: Bool
    let isAwaitingConfirmation: Bool
    let confirmationProgress: Int
    let requiredConfirmationCount: Int
    let shouldTriggerSubscribe: Bool
    let shouldBeep: Bool
}

final class TradingTriggerStateMachine {
    private let manualCellRearmConfirmationFrames: Int
    private let manualCellTriggerConfirmationFrames: Int
    private let manualCellSellMinimumConfidence: Double
    private let manualSymbolTriggerConfirmationFrames: Int
    private let manualSymbolChangedSymbolMinimumConfidence: Double
    private var manualCellIsArmed = true
    private var manualCellZeroLikeStreak = 0
    private var pendingManualCellIntegerValue: Int?
    private var pendingManualCellConfirmationCount = 0
    private var manualCellOpenPositionPeakValue: Int?
    private var manualCellSellWasTriggered = false
    private var lastManualCellText: String?
    private var lastCommittedManualSymbol: String?
    private var pendingManualSymbol: String?
    private var pendingManualSymbolConfirmationCount = 0

    init(
        manualCellRearmConfirmationFrames: Int = 1,
        manualCellTriggerConfirmationFrames: Int = 1,
        manualCellSellMinimumConfidence: Double = 0.70,
        manualSymbolTriggerConfirmationFrames: Int = 1,
        manualSymbolChangedSymbolMinimumConfidence: Double = 0.80
    ) {
        self.manualCellRearmConfirmationFrames = max(1, manualCellRearmConfirmationFrames)
        self.manualCellTriggerConfirmationFrames = max(1, manualCellTriggerConfirmationFrames)
        self.manualCellSellMinimumConfidence = min(max(0, manualCellSellMinimumConfidence), 1)
        self.manualSymbolTriggerConfirmationFrames = max(1, manualSymbolTriggerConfirmationFrames)
        self.manualSymbolChangedSymbolMinimumConfidence = min(
            max(0, manualSymbolChangedSymbolMinimumConfidence),
            1
        )
    }

    func reset() {
        manualCellIsArmed = true
        manualCellZeroLikeStreak = 0
        pendingManualCellIntegerValue = nil
        pendingManualCellConfirmationCount = 0
        manualCellOpenPositionPeakValue = nil
        manualCellSellWasTriggered = false
        lastManualCellText = nil
        lastCommittedManualSymbol = nil
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
    }

    func clearManualSymbolState() {
        lastCommittedManualSymbol = nil
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
    }

    func evaluateManualCell(normalizedText: String, confidence: Double = 1.0) -> ManualCellTriggerEvaluation {
        let integerValue = ManualCellIntegerPolicy.parseInteger(normalizedText)
        let isZeroOrEmpty = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || integerValue == 0
        let isDuplicate = normalizedText == lastManualCellText
        let wasArmed = manualCellIsArmed
        let openPositionPeakBeforeUpdate = manualCellOpenPositionPeakValue
        var shouldTriggerSell = false

        if let integerValue, let openPositionPeakBeforeUpdate, !manualCellSellWasTriggered {
            if integerValue > openPositionPeakBeforeUpdate {
                manualCellOpenPositionPeakValue = integerValue
            } else if integerValue < openPositionPeakBeforeUpdate,
                      isSafeSellDecrease(
                        currentValue: integerValue,
                        peakValue: openPositionPeakBeforeUpdate,
                        confidence: confidence
                      ) {
                shouldTriggerSell = true
            }
        }

        if isZeroOrEmpty {
            manualCellZeroLikeStreak += 1
        } else {
            manualCellZeroLikeStreak = 0
        }

        let shouldRearm = isZeroOrEmpty && manualCellZeroLikeStreak >= manualCellRearmConfirmationFrames
        var confirmationProgress = 0

        if manualCellIsArmed {
            if let integerValue, !isZeroOrEmpty {
                if pendingManualCellIntegerValue == integerValue {
                    pendingManualCellConfirmationCount += 1
                } else {
                    pendingManualCellIntegerValue = integerValue
                    pendingManualCellConfirmationCount = 1
                }
                confirmationProgress = pendingManualCellConfirmationCount
            } else {
                pendingManualCellIntegerValue = nil
                pendingManualCellConfirmationCount = 0
            }
        } else {
            pendingManualCellIntegerValue = nil
            pendingManualCellConfirmationCount = 0
        }

        let shouldTriggerBuy =
            manualCellIsArmed &&
            integerValue != nil &&
            !isZeroOrEmpty &&
            confirmationProgress >= manualCellTriggerConfirmationFrames

        if shouldRearm {
            manualCellIsArmed = true
            pendingManualCellIntegerValue = nil
            pendingManualCellConfirmationCount = 0
            manualCellOpenPositionPeakValue = nil
            manualCellSellWasTriggered = false
        }

        if !isDuplicate {
            lastManualCellText = normalizedText
        }

        return ManualCellTriggerEvaluation(
            normalizedText: normalizedText,
            integerValue: integerValue,
            openPositionPeakValue: openPositionPeakBeforeUpdate,
            isZeroOrEmpty: isZeroOrEmpty,
            isDuplicate: isDuplicate,
            isAwaitingConfirmation:
                manualCellIsArmed &&
                integerValue != nil &&
                !isZeroOrEmpty &&
                !shouldTriggerBuy &&
                !shouldTriggerSell &&
                confirmationProgress > 0,
            confirmationProgress: confirmationProgress,
            requiredConfirmationCount: manualCellTriggerConfirmationFrames,
            shouldTriggerBuy: shouldTriggerBuy,
            shouldTriggerSell: shouldTriggerSell,
            shouldBeep: !isDuplicate,
            wasArmed: wasArmed,
            isArmedAfter: manualCellIsArmed
        )
    }

    func evaluateManualSymbol(normalizedText: String, confidence: Double) -> ManualSymbolTriggerEvaluation {
        let normalizedSymbol = TradingMessageContract.normalizedOCRSymbol(normalizedText) ?? ""
        let isDuplicate = !normalizedSymbol.isEmpty && normalizedSymbol == lastCommittedManualSymbol
        let hasCommittedSymbol = lastCommittedManualSymbol != nil
        let isLowConfidenceChangedSymbol =
            hasCommittedSymbol &&
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            confidence < manualSymbolChangedSymbolMinimumConfidence
        let isChangeLocked =
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            lastCommittedManualSymbol != nil &&
            isLowConfidenceChangedSymbol
        var confirmationProgress = 0

        if normalizedSymbol.isEmpty || isDuplicate || isChangeLocked {
            pendingManualSymbol = nil
            pendingManualSymbolConfirmationCount = 0
        } else if pendingManualSymbol == normalizedSymbol {
            pendingManualSymbolConfirmationCount += 1
            confirmationProgress = pendingManualSymbolConfirmationCount
        } else {
            pendingManualSymbol = normalizedSymbol
            pendingManualSymbolConfirmationCount = 1
            confirmationProgress = pendingManualSymbolConfirmationCount
        }

        let shouldTriggerSubscribe =
            !normalizedSymbol.isEmpty &&
            !isDuplicate &&
            !isChangeLocked &&
            confirmationProgress >= manualSymbolTriggerConfirmationFrames

        return ManualSymbolTriggerEvaluation(
            normalizedSymbol: normalizedSymbol,
            isDuplicate: isDuplicate,
            isChangeLocked: isChangeLocked,
            isAwaitingConfirmation:
                !normalizedSymbol.isEmpty &&
                !isDuplicate &&
                !isChangeLocked &&
                !shouldTriggerSubscribe &&
                confirmationProgress > 0,
            confirmationProgress: confirmationProgress,
            requiredConfirmationCount: manualSymbolTriggerConfirmationFrames,
            shouldTriggerSubscribe: shouldTriggerSubscribe,
            shouldBeep: shouldTriggerSubscribe
        )
    }

    func commitManualCellTriggerSuccess(openPositionIntegerValue: Int? = nil) {
        manualCellIsArmed = false
        pendingManualCellIntegerValue = nil
        pendingManualCellConfirmationCount = 0
        if let openPositionIntegerValue, openPositionIntegerValue > 0 {
            manualCellOpenPositionPeakValue = openPositionIntegerValue
            manualCellSellWasTriggered = false
        } else {
            manualCellOpenPositionPeakValue = nil
            manualCellSellWasTriggered = false
        }
    }

    func commitManualCellSellSuccess() {
        manualCellOpenPositionPeakValue = nil
        manualCellSellWasTriggered = true
    }

    private func isSafeSellDecrease(currentValue: Int, peakValue: Int, confidence: Double) -> Bool {
        guard confidence >= manualCellSellMinimumConfidence else {
            return false
        }

        if currentValue == 0 {
            return true
        }

        let currentDigitCount = digitCount(currentValue)
        let peakDigitCount = digitCount(peakValue)
        let looksLikeDroppedDigit =
            currentDigitCount < peakDigitCount &&
            Double(currentValue) < Double(peakValue) * 0.5
        return !looksLikeDroppedDigit
    }

    private func digitCount(_ value: Int) -> Int {
        String(abs(value)).count
    }

    func commitManualSymbolTriggerSuccess(symbol: String) {
        lastCommittedManualSymbol = TradingMessageContract.normalizeSymbol(symbol)
        pendingManualSymbol = nil
        pendingManualSymbolConfirmationCount = 0
    }
}
