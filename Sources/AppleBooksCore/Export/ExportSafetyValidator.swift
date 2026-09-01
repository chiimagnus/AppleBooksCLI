import Foundation

struct AnnotationArchiveRawTotals: Equatable, Sendable {
    var noteCount = 0
    var highlightCount = 0
    var unmappedNoteCount = 0
    var noteWithoutQuoteCount = 0
}

public enum ExportSafetyValidationError: Error, Equatable, Sendable {
    case incompleteArchiveDataset
    case unmappedNotes(count: Int)
    case notesMissingQuote(count: Int)
    case rawNoteCountMismatch(expected: Int, actual: Int)
    case rawHighlightCountMismatch(expected: Int, actual: Int)
    case materializedDocumentCountMismatch(expected: Int, actual: Int)
}

enum ExportSafetyValidator {
    static func requiresCompleteNoteArchiveValidation(_ options: ExportOptions) -> Bool {
        options.completeNotes
    }

    static func validateDataset(
        _ bundle: ExportBundle,
        rawTotals: AnnotationArchiveRawTotals
    ) throws {
        guard requiresCompleteNoteArchiveValidation(bundle.options) else {
            throw ExportSafetyValidationError.incompleteArchiveDataset
        }
        if rawTotals.unmappedNoteCount > 0 {
            throw ExportSafetyValidationError.unmappedNotes(count: rawTotals.unmappedNoteCount)
        }
        if rawTotals.noteWithoutQuoteCount > 0 {
            throw ExportSafetyValidationError.notesMissingQuote(count: rawTotals.noteWithoutQuoteCount)
        }

        var actualNotes = 0
        var actualHighlights = 0
        for group in bundle.groups {
            for record in group.records {
                guard case let .epub(enriched) = record.payload else { continue }
                let annotation = enriched.annotation
                if let note = annotation.note, note.isEmpty == false {
                    actualNotes += 1
                }
                if let selectedText = annotation.selectedText, selectedText.isEmpty == false {
                    actualHighlights += 1
                }
            }
        }

        guard actualNotes == rawTotals.noteCount else {
            throw ExportSafetyValidationError.rawNoteCountMismatch(
                expected: rawTotals.noteCount,
                actual: actualNotes
            )
        }
        guard actualHighlights == rawTotals.highlightCount else {
            throw ExportSafetyValidationError.rawHighlightCountMismatch(
                expected: rawTotals.highlightCount,
                actual: actualHighlights
            )
        }
    }

    static func validateMaterialization(expectedDocuments: Int, actualDocuments: Int) throws {
        guard expectedDocuments == actualDocuments else {
            throw ExportSafetyValidationError.materializedDocumentCountMismatch(
                expected: expectedDocuments,
                actual: actualDocuments
            )
        }
    }
}
