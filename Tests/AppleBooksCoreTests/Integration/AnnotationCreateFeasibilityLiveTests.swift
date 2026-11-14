import Foundation
import XCTest
@testable import AppleBooksCore

// Live native writes are opt-in, restricted to previously imported synthetic EPUB fixtures.
final class AnnotationCreateFeasibilityLiveTests: XCTestCase {
    private struct Sample {
        let title: String
        let text: String
        let chapter: String
        let note: String?
        let color: AnnotationColor
        let underline: Bool

        static func named(_ key: String) -> Sample? {
            switch key {
            case "A":
                return Sample(
                    title: "AppleBooksCLI P1T1 Synthetic A 20261114",
                    text: "telescope",
                    chapter: "The quiet telescope watched a silver valley.",
                    note: "P2T2 synthetic native creation verification.",
                    color: .green, underline: false
                )
            case "B":
                return Sample(
                    title: "AppleBooksCLI P1T1 Synthetic B 20261114",
                    text: "crystal",
                    chapter: "The brave turtle walked past a crystal bridge.",
                    note: nil,
                    color: .purple, underline: true
                )
            default:
                return nil
            }
        }
    }

    func testLiveSyntheticCreationUsesOnlyTheProductionCoreAndCloudBridge() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["APPLEBOOKSCLI_P2T2_ALLOW_SYNTHETIC_WRITE"] == "YES",
              let assetID = environment["APPLEBOOKSCLI_P2T2_ASSET_ID"],
              let sample = environment["APPLEBOOKSCLI_P2T2_CASE"].flatMap(Sample.named) else {
            throw XCTSkip("Explicit native synthetic-book write opt-in required")
        }

        let stores = try DatabaseDiscovery().discover()
        let library = try SQLiteConnection.readOnly(path: stores.libraryDB.path)
        defer { try? library.close() }
        let statement = try library.prepare("""
            SELECT ZTITLE,ZAUTHOR FROM ZBKLIBRARYASSET
            WHERE ZASSETID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { throw LiveError.notSyntheticBook }
        let row = try SQLiteRow(statement: statement)
        guard try row.text("ZTITLE") == sample.title,
              try row.text("ZAUTHOR") == "AppleBooksCLI Test Fixture",
              try statement.step() == false else {
            throw LiveError.notSyntheticBook
        }
        let bookQueries = BookQueries(connection: library)
        let locator = try EPUBAnnotationLocator(
            assetID: assetID, bookQueries: bookQueries, configuration: .empty
        )
        let chapter = try XCTUnwrap(locator.content.listChapters().first)
        XCTAssertTrue(try locator.content.getChapter(chapter.id).contains(sample.chapter))
        let selected = try locator.locate(sample.text)
        XCTAssertEqual(selected.selectedText, sample.text)
        XCTAssertEqual(selected.bookIdentity?.assetID, assetID)

        let app = try AppleBooks(
            libraryDB: stores.libraryDB, annotationsDB: stores.annotationsDB,
            configurationFile: nil,
            dependencies: [.libraryRead, .annotationsRead, .configuration, .annotationWrite],
            manageCollectionBooksApplication: false,
            manageAnnotationBooksApplication: true
        )
        let created = try app.createAnnotation(
            assetID: assetID, text: sample.text, note: sample.note,
            color: sample.color, underline: sample.underline
        )
        XCTAssertTrue(created.changed, "The first synthetic creation must commit exactly once")
        XCTAssertTrue(created.committed)
        XCTAssertTrue(created.warnings.isEmpty, "Native new UUID projection must succeed")
        let uuid = try XCTUnwrap(created.stableID)
        let readBack = try XCTUnwrap(app.semanticAnnotation(uuid: uuid))
        XCTAssertEqual(readBack.selectedText, sample.text)
        XCTAssertEqual(readBack.note, sample.note)
        XCTAssertEqual(readBack.style, sample.color.rawValue)
        XCTAssertEqual(readBack.isUnderline, sample.underline)
        let replay = try app.createAnnotation(
            assetID: assetID, text: sample.text, note: sample.note,
            color: sample.color, underline: sample.underline
        )
        XCTAssertFalse(replay.changed)
        XCTAssertEqual(replay.stableID, uuid)
    }

    private enum LiveError: Error { case notSyntheticBook }
}
