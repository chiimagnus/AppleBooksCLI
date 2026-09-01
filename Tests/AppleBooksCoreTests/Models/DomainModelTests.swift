import Foundation
import Testing
@testable import AppleBooksCore

@Suite("DomainModelTests")
struct DomainModelTests {
    @Test
    func bookPreservesRawProgressAndNullableFinishedState() {
        let book = Book(
            localPK: 7,
            assetID: nil,
            title: nil,
            author: nil,
            description: nil,
            epubID: nil,
            genre: nil,
            genresRaw: nil,
            comments: nil,
            language: nil,
            year: nil,
            contentType: nil,
            pageCount: nil,
            path: nil,
            fileSize: nil,
            coverURL: nil,
            isFinished: nil,
            readingProgressRaw: 1.25,
            durationRawMilliseconds: 3_600_000,
            creationDate: nil,
            modificationDate: nil,
            finishedDate: nil,
            lastOpenDate: nil,
            purchaseDate: nil,
            releaseDate: nil,
            isExplicit: nil,
            isLocked: nil,
            isEphemeral: nil,
            isHidden: nil,
            isSample: nil,
            isStoreAudiobook: nil,
            rating: nil
        )
        #expect(book.readingProgressRaw == 1.25)
        #expect(book.readingProgressPercent == 125)
        #expect(book.durationRawMilliseconds == 3_600_000)
        #expect(book.durationSeconds == 3_600)
        #expect(book.isFinished == nil)
    }

    @Test
    func annotationPreservesUnknownRawStyleAndOptionalIdentity() {
        let annotation = Annotation(
            localPK: 9,
            uuid: nil,
            rawAssetID: nil,
            isDeleted: nil,
            isUnderline: nil,
            style: 99,
            type: nil,
            createdAt: nil,
            modifiedAt: nil,
            representativeText: nil,
            selectedText: nil,
            note: "synthetic note",
            location: nil,
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil
        )
        #expect(annotation.uuid == nil)
        #expect(annotation.rawAssetID == nil)
        #expect(annotation.style == 99)
        #expect(annotation.type == nil)
        #expect(annotation.isDeleted == nil)
    }

    @Test
    func collectionKeepsLocalAndSourceIdentitySeparate() {
        let collection = Collection(
            localPK: 3,
            collectionID: nil,
            title: "Synthetic Shelf",
            details: nil,
            isDeleted: false,
            isHidden: nil,
            isPlaceholder: nil,
            sortKey: 42,
            sortMode: nil,
            viewMode: nil,
            lastModificationDate: nil,
            localModificationDate: nil
        )
        #expect(collection.localPK == 3)
        #expect(collection.collectionID == nil)
        #expect(collection.title == "Synthetic Shelf")
        #expect(collection.sortKey == 42)
    }
}
