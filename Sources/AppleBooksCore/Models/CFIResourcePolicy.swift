import Foundation

enum CFIResourcePolicy {
    static let maximumStructuralBytes = 64 * 1_024

    static func allowsStructuralParsing(_ raw: String) -> Bool {
        var byteCount = 0
        for _ in raw.utf8 {
            byteCount += 1
            if byteCount > maximumStructuralBytes {
                return false
            }
        }
        return true
    }
}

struct CFIStructureParseResult: Sendable {
    let chapterID: String?
    let rangeStart: Int?
    let rangeEnd: Int?
    let readingNumbers: [Int]?
}

enum CFIStructureParser {
    static func parse(_ raw: String, collectReadingNumbers: Bool = false) -> CFIStructureParseResult? {
        guard CFIResourcePolicy.allowsStructuralParsing(raw) else { return nil }
        guard let bounds = trimmedBounds(in: raw) else { return nil }
        let trimmed = raw[bounds]
        let prefix = "epubcfi("
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { return nil }

        let bodyStart = raw.index(bounds.lowerBound, offsetBy: prefix.count)
        let bodyEnd = raw.index(before: bounds.upperBound)
        guard bodyStart <= bodyEnd else { return nil }

        var chapterID: String?
        var inSpine = true
        var assertionStart: String.Index?

        var rangeStartContentStart: String.Index?
        var rangeStartContentEnd: String.Index?
        var rangeEndContentStart: String.Index?

        var readingNumbers = collectReadingNumbers ? [Int]() : nil
        var currentNumber = 0
        var hasNumberDigits = false
        var readingNumbersValid = true

        func flushNumber() {
            guard collectReadingNumbers, hasNumberDigits else { return }
            if readingNumbersValid {
                readingNumbers?.append(currentNumber)
            }
            currentNumber = 0
            hasNumberDigits = false
        }

        var index = bodyStart
        while index < bodyEnd {
            let character = raw[index]
            let next = raw.index(after: index)

            if let open = assertionStart {
                if character == "[" {
                    return nil
                }
                if character == "]" {
                    if inSpine, open < index {
                        chapterID = String(raw[open..<index])
                    }
                    assertionStart = nil
                }
                index = next
                continue
            }

            if character == "[" {
                flushNumber()
                assertionStart = next
                index = next
                continue
            }
            if character == "]" {
                return nil
            }
            if character == "!" {
                flushNumber()
                inSpine = false
                index = next
                continue
            }

            if character == ",", next < bodyEnd, raw[next] == ":" {
                flushNumber()
                let afterColon = raw.index(after: next)
                if let previousEndStart = rangeEndContentStart {
                    rangeStartContentStart = previousEndStart
                    rangeStartContentEnd = index
                }
                rangeEndContentStart = afterColon
                index = afterColon
                continue
            }

            if collectReadingNumbers, let digit = asciiDigit(character) {
                if readingNumbersValid {
                    let multiplied = currentNumber.multipliedReportingOverflow(by: 10)
                    let added = multiplied.partialValue.addingReportingOverflow(digit)
                    if multiplied.overflow || added.overflow {
                        readingNumbersValid = false
                        readingNumbers = nil
                    } else {
                        currentNumber = added.partialValue
                    }
                }
                hasNumberDigits = true
            } else {
                flushNumber()
            }
            index = next
        }

        guard assertionStart == nil else { return nil }
        flushNumber()

        let characterRange: (Int, Int)?
        if let start = rangeStartContentStart,
           let startEnd = rangeStartContentEnd,
           let endStart = rangeEndContentStart,
           let startValue = Int(raw[start..<startEnd]),
           let endValue = parseRangeEnd(raw[endStart..<bodyEnd]) {
            characterRange = (startValue, endValue)
        } else {
            characterRange = nil
        }

        let finalReadingNumbers: [Int]?
        if collectReadingNumbers, readingNumbersValid, let values = readingNumbers, values.isEmpty == false {
            finalReadingNumbers = values
        } else {
            finalReadingNumbers = nil
        }

        return CFIStructureParseResult(
            chapterID: chapterID,
            rangeStart: characterRange?.0,
            rangeEnd: characterRange?.1,
            readingNumbers: finalReadingNumbers
        )
    }

    private static func trimmedBounds(in raw: String) -> Range<String.Index>? {
        var lower = raw.startIndex
        while lower < raw.endIndex, raw[lower].isWhitespace {
            lower = raw.index(after: lower)
        }
        guard lower < raw.endIndex else { return nil }

        var upper = raw.endIndex
        while upper > lower {
            let previous = raw.index(before: upper)
            guard raw[previous].isWhitespace else { break }
            upper = previous
        }
        return lower..<upper
    }

    private static func asciiDigit(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.value >= 48,
              scalar.value <= 57 else {
            return nil
        }
        return Int(scalar.value - 48)
    }

    private static func parseRangeEnd(_ value: Substring) -> Int? {
        var upper = value.endIndex
        while upper > value.startIndex {
            let previous = value.index(before: upper)
            guard value[previous].isWhitespace else { break }
            upper = previous
        }
        guard value.startIndex < upper else { return nil }
        return Int(value[value.startIndex..<upper])
    }
}
