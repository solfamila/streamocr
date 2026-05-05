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
