import Foundation
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("SemanticTextBoundaryDTOTests")
struct SemanticTextBoundaryDTOTests {
    @Test
    func collectionJSONKeepsCoreByteEvidenceAndAppliesCLIWholeGraphemeBudget() throws {
        let collection = SemanticCollection(
            localPK: 1,
            collectionID: nil,
            title: String(repeating: "t", count: SQLiteSemanticTextBudget.metadata),
            details: String(repeating: "d", count: SQLiteSemanticTextBudget.detail),
            isDeleted: false,
            isHidden: false,
            isPlaceholder: false,
            sortKey: nil,
            sortMode: nil,
            viewMode: nil,
            lastModificationDate: nil,
            localModificationDate: nil,
            byteTruncatedFields: ["title", "details"]
        )

        let result = CollectionResult(collection)
        #expect(result.title?.count == BoundedTextProfile.metadata.maximumGraphemes)
        #expect(result.details?.count == BoundedTextProfile.detail.maximumGraphemes)
        #expect(result.truncatedFields == ["details", "title"])

        let data = try JSONEncoder().encode(result)
        #expect(data.count < 8 * 1_024)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["truncatedFields"] as? [String]) == ["details", "title"])
    }

    @Test
    func annotationJSONPreservesBodyAndSourceTruncationEvidence() throws {
        let source = SemanticAnnotationSource(
            kind: .currentLibrary,
            bookLocalPK: 10,
            bookAssetID: "asset",
            title: String(repeating: "s", count: SQLiteSemanticTextBudget.metadata),
            author: "author",
            byteTruncatedFields: ["title"]
        )
        let annotation = SemanticAnnotation(
            localPK: 1,
            uuid: "uuid",
            rawAssetID: "asset",
            isDeleted: false,
            isUnderline: false,
            style: 1,
            type: 1,
            createdAt: nil,
            modifiedAt: nil,
            representativeText: String(repeating: "r", count: SQLiteSemanticTextBudget.preview),
            selectedText: String(repeating: "s", count: SQLiteSemanticTextBudget.preview),
            note: String(repeating: "n", count: SQLiteSemanticTextBudget.preview),
            rawCFI: nil,
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil,
            source: source,
            byteTruncatedFields: ["representativeText", "selectedText", "note"]
        )

        let result = AnnotationResult(annotation)
        #expect(result.representativeText?.count == BoundedTextProfile.preview.maximumGraphemes)
        #expect(result.selectedText?.count == BoundedTextProfile.preview.maximumGraphemes)
        #expect(result.note?.count == BoundedTextProfile.preview.maximumGraphemes)
        #expect(result.source.title?.count == BoundedTextProfile.metadata.maximumGraphemes)
        #expect(Set(result.truncatedFields) == ["representativeText", "selectedText", "note", "source.title"])

        let data = try JSONEncoder().encode(result)
        #expect(data.count < 8 * 1_024)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set((json["truncatedFields"] as? [String]) ?? []) == ["representativeText", "selectedText", "note", "source.title"])
    }
}
