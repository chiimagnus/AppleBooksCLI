import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ExportSafetyValidatorTests")
struct ExportSafetyValidatorTests {
    @Test
    func completeArchiveGateOnlyMatchesUnfilteredEPUBOrAllExports() throws {
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(try ExportOptions()))
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(try ExportOptions(source: .all)))
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(try ExportOptions(source: .pdf)) == false)
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(
            try ExportOptions(bookSelectors: [.assetID("one")])
        ) == false)
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(
            try ExportOptions(kinds: [.note])
        ) == false)
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(
            try ExportOptions(colors: [.yellow])
        ) == false)
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(
            try ExportOptions(underline: true)
        ) == false)
        #expect(ExportSafetyValidator.requiresCompleteNoteArchiveValidation(
            try ExportOptions(skipFirstPerBook: 1)
        ) == false)
    }

    @Test
    func unmappedHighlightOnlyAndMappedHistoricalNoteAreAllowed() throws {
        let historical = HistoricalBookMetadata(title: "History", author: "Author")
        let groups = [
            ExportGroup(
                source: .epubUnmapped(assetID: "orphan"),
                records: [record(pk: 1, assetID: "orphan", selected: "orphan quote", note: nil, source: .unmapped)]
            ),
            ExportGroup(
                source: .epubHistorical(assetID: "history", metadata: historical),
                records: [record(
                    pk: 2,
                    assetID: "history",
                    selected: "history quote",
                    note: "history note",
                    source: .historicalInferred(historical)
                )]
            ),
        ]
        let bundle = bundle(groups: groups)
        let raw = AnnotationArchiveRawTotals(
            noteCount: 1,
            highlightCount: 2,
            unmappedNoteCount: 0,
            noteWithoutQuoteCount: 0
        )

        try ExportSafetyValidator.validateDataset(bundle, rawTotals: raw)
    }

    @Test
    func unmappedWhitespaceNoteFailsWithoutLeakingIdentityOrText() throws {
        let group = ExportGroup(
            source: .epubUnmapped(assetID: "sensitive-id"),
            records: [record(pk: 1, assetID: "sensitive-id", selected: nil, note: "   ", source: .unmapped)]
        )
        let bundle = bundle(groups: [group])
        let raw = AnnotationArchiveRawTotals(
            noteCount: 1,
            highlightCount: 0,
            unmappedNoteCount: 1,
            noteWithoutQuoteCount: 1
        )

        #expect(throws: ExportSafetyValidationError.unmappedNotes(count: 1)) {
            try ExportSafetyValidator.validateDataset(bundle, rawTotals: raw)
        }
    }

    @Test
    func mappedNoteWithoutSelectedOrRepresentativeQuoteFails() throws {
        let historical = HistoricalBookMetadata(title: "History", author: "Author")
        let group = ExportGroup(
            source: .epubHistorical(assetID: "history", metadata: historical),
            records: [record(
                pk: 1,
                assetID: "history",
                selected: nil,
                representative: nil,
                note: "note",
                source: .historicalInferred(historical)
            )]
        )
        let raw = AnnotationArchiveRawTotals(
            noteCount: 1,
            highlightCount: 0,
            unmappedNoteCount: 0,
            noteWithoutQuoteCount: 1
        )

        #expect(throws: ExportSafetyValidationError.notesMissingQuote(count: 1)) {
            try ExportSafetyValidator.validateDataset(bundle(groups: [group]), rawTotals: raw)
        }
    }

    @Test
    func mappedWhitespaceOnlyNoteWithoutQuoteFailsAsMissingQuote() throws {
        let historical = HistoricalBookMetadata(title: "History", author: "Author")
        let group = ExportGroup(
            source: .epubHistorical(assetID: "history", metadata: historical),
            records: [record(
                pk: 1,
                assetID: "history",
                selected: nil,
                representative: nil,
                note: "   ",
                source: .historicalInferred(historical)
            )]
        )
        #expect(throws: ExportSafetyValidationError.notesMissingQuote(count: 1)) {
            try ExportSafetyValidator.validateDataset(
                bundle(groups: [group]),
                rawTotals: AnnotationArchiveRawTotals(
                    noteCount: 1,
                    highlightCount: 0,
                    unmappedNoteCount: 0,
                    noteWithoutQuoteCount: 1
                )
            )
        }
    }

    @Test
    func independentRawCountsMustMatchFinalEPUBRecords() throws {
        let book = makeBook(pk: 1, assetID: "book", title: "Book", contentType: 1)
        let group = ExportGroup(
            source: .epubCurrent(book),
            records: [record(
                pk: 1,
                assetID: "book",
                selected: "quote",
                note: "note",
                source: .currentLibrary(book)
            )]
        )
        let value = bundle(groups: [group])

        #expect(throws: ExportSafetyValidationError.rawNoteCountMismatch(expected: 2, actual: 1)) {
            try ExportSafetyValidator.validateDataset(
                value,
                rawTotals: AnnotationArchiveRawTotals(
                    noteCount: 2,
                    highlightCount: 1,
                    unmappedNoteCount: 0,
                    noteWithoutQuoteCount: 0
                )
            )
        }
        #expect(throws: ExportSafetyValidationError.rawHighlightCountMismatch(expected: 2, actual: 1)) {
            try ExportSafetyValidator.validateDataset(
                value,
                rawTotals: AnnotationArchiveRawTotals(
                    noteCount: 1,
                    highlightCount: 2,
                    unmappedNoteCount: 0,
                    noteWithoutQuoteCount: 0
                )
            )
        }
    }

    @Test
    func materializedDocumentCountMismatchFailsClosed() {
        #expect(throws: ExportSafetyValidationError.materializedDocumentCountMismatch(expected: 2, actual: 1)) {
            try ExportSafetyValidator.validateMaterialization(expectedDocuments: 2, actualDocuments: 1)
        }
    }

    @Test
    func aggregateUsesActiveRawPredicateAndExcludesOnlyKnownCurrentPDFAnnotations() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "epub", contentType: 1),
            .init(pk: 2, assetID: "pdf", contentType: 3),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, deleted: 0, assetID: "epub", selected: "epub quote", representative: nil, note: "epub note"),
            .init(pk: 2, deleted: 0, assetID: "pdf", selected: "pdf quote", representative: nil, note: "pdf note"),
            .init(pk: 3, deleted: 0, assetID: "orphan", selected: "orphan quote", representative: nil, note: nil),
            .init(pk: 4, deleted: nil, assetID: "null-deleted", selected: "must not count", representative: nil, note: "must not count"),
        ])

        let totals = try fixture.annotationQueries().completeNoteArchiveRawTotals()

        #expect(totals.noteCount == 1)
        #expect(totals.highlightCount == 2)
        #expect(totals.unmappedNoteCount == 0)
        #expect(totals.noteWithoutQuoteCount == 0)
    }

    @Test
    func mappedWhitespaceNoteWithRepresentativeQuoteFailsCountInsteadOfSilentlyDropping() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "book", contentType: 1),
        ])
        try fixture.createAnnotations([
            .init(
                pk: 1,
                deleted: 0,
                assetID: "book",
                selected: nil,
                representative: "representative quote",
                note: "   "
            ),
        ])

        #expect(throws: ExportSafetyValidationError.rawNoteCountMismatch(expected: 1, actual: 0)) {
            _ = try fixture.service().makeBundle(options: ExportOptions())
        }
    }

    @Test
    func completeArchiveRequiresSafetyColumnsButFilteredExportDoesNot() throws {
        let fixture = try DatabaseFixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations(
            [.init(pk: 1, deleted: 0, assetID: "orphan", selected: "quote", representative: nil, note: nil)],
            includeRepresentativeColumn: false
        )

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: [AppleBooksSchema.Annotation.representativeText]
        )) {
            _ = try fixture.service().makeBundle(options: ExportOptions())
        }

        let filtered = try fixture.service().makeBundle(options: ExportOptions(kinds: [.highlight]))
        #expect(filtered.statistics.epubAnnotationCount == 1)
    }

    @Test
    func genericPerBookWriterCannotBypassCompleteArchiveStaging() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("ordinary-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let writer = try ExportFileWriter(outputRoot: output)

        #expect(throws: ExportFileWriterError.completeArchiveRequiresStaging) {
            _ = try writer.writeMarkdown(
                bundle(groups: [currentGroup(pk: 1, title: "One")]),
                layout: .perBook
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test
    func stagedArchivePublishesOnlyAfterDocumentCountValidation() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let final = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        let value = bundle(groups: [
            currentGroup(pk: 1, title: "One"),
            currentGroup(pk: 2, title: "Two"),
        ])

        let result = try ExportFileWriter.writeCompleteNoteArchiveMarkdown(value, to: final)

        #expect(result.documentFileCount == 2)
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(result.files.allSatisfy { $0.path.hasPrefix(final.path + "/") })
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    @Test
    func existingArchiveDirectoryIsNeverMixedOrOverwritten() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let final = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
        let marker = final.appendingPathComponent("user-file.txt")
        try Data("keep".utf8).write(to: marker)

        #expect(throws: ExportFileWriterError.archiveDestinationExists) {
            _ = try ExportFileWriter.writeCompleteNoteArchiveMarkdown(
                bundle(groups: [currentGroup(pk: 1, title: "One")]),
                to: final
            )
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    @Test
    func materializationMismatchInsideStagingLeavesFinalAbsentAndCleansOwnedStaging() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let final = fixture.root.appendingPathComponent("Archive", isDirectory: true)

        #expect(throws: ExportSafetyValidationError.materializedDocumentCountMismatch(expected: 2, actual: 1)) {
            _ = try ExportFileWriter.publishArchiveDirectory(
                to: final,
                expectedDocuments: 2,
                now: Date.init,
                beforeArchiveRename: nil
            ) { writer in
                try writer.writeMarkdown(
                    bundle(groups: [currentGroup(pk: 1, title: "One")]),
                    layout: .perBook
                )
            }
        }
        #expect(FileManager.default.fileExists(atPath: final.path) == false)
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    @Test
    func midWriteFailureLeavesFinalAbsentAndCleansOwnedStaging() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let final = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        let unsupported = EPUBCover(
            data: Data("not-image".utf8),
            declaredMediaType: "application/octet-stream",
            detectedMediaType: nil,
            source: .metadataID
        )
        let book = makeBook(pk: 1, assetID: "book", title: "Book", contentType: 1)
        let group = ExportGroup(
            source: .epubCurrent(book),
            records: [record(pk: 1, assetID: "book", selected: "quote", note: nil, source: .currentLibrary(book))],
            epubCover: unsupported
        )

        #expect(throws: ExportFileWriterError.unsupportedCoverMediaType) {
            _ = try ExportFileWriter.writeCompleteNoteArchiveMarkdown(
                bundle(groups: [group]),
                to: final,
                profile: .plain,
                coverMode: .file
            )
        }
        #expect(FileManager.default.fileExists(atPath: final.path) == false)
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    @Test
    func finalTargetRaceCannotReplaceRacerAndOwnedStagingIsCleaned() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let final = fixture.root.appendingPathComponent("Archive", isDirectory: true)
        let marker = final.appendingPathComponent("racer.txt")

        #expect(throws: ExportFileWriterError.archiveDestinationExists) {
            _ = try ExportFileWriter.writeCompleteNoteArchiveMarkdown(
                bundle(groups: [currentGroup(pk: 1, title: "One")]),
                to: final,
                profile: .plain,
                coverMode: .none,
                now: Date.init,
                beforeArchiveRename: {
                    try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
                    try Data("race-winner".utf8).write(to: marker)
                }
            )
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "race-winner")
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    private func stagingNames(in parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            $0.hasPrefix(".applebookscli-archive-") && $0.hasSuffix(".staging")
        }
    }

    private func currentGroup(pk: Int64, title: String) -> ExportGroup {
        let book = makeBook(pk: pk, assetID: "asset-\(pk)", title: title, contentType: 1)
        return ExportGroup(
            source: .epubCurrent(book),
            records: [record(
                pk: pk,
                assetID: book.assetID,
                selected: "quote-\(pk)",
                note: nil,
                source: .currentLibrary(book)
            )]
        )
    }

    private func bundle(groups: [ExportGroup]) -> ExportBundle {
        let count = groups.reduce(0) { $0 + $1.records.count }
        return ExportBundle(
            options: try! ExportOptions(),
            groups: groups,
            warnings: [],
            statistics: ExportStatistics(
                documentCount: groups.count,
                epubDocumentCount: groups.count,
                pdfDocumentCount: 0,
                recordCount: count,
                epubAnnotationCount: count,
                pdfHighlightCount: 0,
                highlightCount: count,
                noteCount: 0,
                bookmarkCount: 0,
                historicalEPUBAnnotationCount: 0,
                unmappedEPUBAnnotationCount: 0
            ),
            sourceTotals: ExportSourceTotals(
                epubDocumentCount: groups.count,
                epubAnnotationCount: count,
                pdfAttemptedDocumentCount: 0,
                pdfSucceededDocumentCount: 0,
                pdfFailedDocumentCount: 0,
                pdfHighlightCount: 0
            )
        )
    }

    private func record(
        pk: Int64,
        assetID: String?,
        selected: String?,
        representative: String? = nil,
        note: String?,
        source: AnnotationSource
    ) -> ExportRecord {
        ExportRecord(payload: .epub(EnrichedAnnotation(
            annotation: Annotation(
                localPK: pk,
                uuid: nil,
                rawAssetID: assetID,
                isDeleted: false,
                isUnderline: false,
                style: nil,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: representative,
                selectedText: selected,
                note: note,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            ),
            source: source
        )))
    }

    private func makeBook(
        pk: Int64,
        assetID: String,
        title: String,
        contentType: Int64
    ) -> Book {
        Book(
            localPK: pk,
            assetID: assetID,
            title: title,
            author: nil,
            description: nil,
            epubID: nil,
            genre: nil,
            genresRaw: nil,
            comments: nil,
            language: nil,
            year: nil,
            contentType: contentType,
            pageCount: nil,
            path: nil,
            fileSize: nil,
            coverURL: nil,
            isFinished: nil,
            readingProgressRaw: nil,
            durationRawMilliseconds: nil,
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
    }

    private final class ArchiveFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class DatabaseFixture {
        let root: URL
        let libraryURL: URL
        let annotationsURL: URL
        let configURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            libraryURL = root.appendingPathComponent("library.sqlite")
            annotationsURL = root.appendingPathComponent("annotations.sqlite")
            configURL = root.appendingPathComponent("config.json")
            try Data("{}".utf8).write(to: configURL)
        }

        func createLibrary(_ rows: [BookRow]) throws {
            var sql = """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZCONTENTTYPE INTEGER
            );
            """
            if rows.isEmpty == false {
                sql += "INSERT INTO ZBKLIBRARYASSET VALUES " + rows.map {
                    "(\($0.pk),\(quote($0.assetID)),\($0.contentType))"
                }.joined(separator: ",") + ";"
            }
            try createDatabase(libraryURL, sql: sql)
        }

        func createAnnotations(
            _ rows: [AnnotationRow],
            includeRepresentativeColumn: Bool = true
        ) throws {
            let representativeDefinition = includeRepresentativeColumn
                ? ", ZANNOTATIONREPRESENTATIVETEXT TEXT"
                : ""
            var sql = """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONSELECTEDTEXT TEXT\(representativeDefinition),
              ZANNOTATIONNOTE TEXT
            );
            """
            if rows.isEmpty == false {
                let values = rows.map { row -> String in
                    var fields = [
                        String(row.pk),
                        row.deleted.map(String.init) ?? "NULL",
                        "1",
                        quote(row.assetID),
                        quote(row.selected),
                    ]
                    if includeRepresentativeColumn { fields.append(quote(row.representative)) }
                    fields.append(quote(row.note))
                    return "(" + fields.joined(separator: ",") + ")"
                }
                sql += "INSERT INTO ZAEANNOTATION VALUES " + values.joined(separator: ",") + ";"
            }
            try createDatabase(annotationsURL, sql: sql)
        }

        func annotationQueries() throws -> AnnotationQueries {
            let bookQueries = BookQueries(connection: try SQLiteConnection.readOnly(path: libraryURL.path))
            return AnnotationQueries(
                annotationConnection: try SQLiteConnection.readOnly(path: annotationsURL.path),
                bookQueries: bookQueries,
                historicalAssets: HistoricalAssets()
            )
        }

        func service() throws -> ExportService {
            let library = try SQLiteConnection.readOnly(path: libraryURL.path)
            let books = BookQueries(connection: library)
            let configuration = try AppleBooksConfiguration(fileURL: configURL)
            return ExportService(
                annotationQueries: AnnotationQueries(
                    annotationConnection: try SQLiteConnection.readOnly(path: annotationsURL.path),
                    bookQueries: books,
                    historicalAssets: configuration.historicalAssets
                ),
                bookQueries: books,
                configuration: configuration,
                pdfService: nil
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
                throw FixtureError.database
            }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        private func quote(_ value: String?) -> String {
            guard let value else { return "NULL" }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    private struct BookRow {
        let pk: Int64
        let assetID: String
        let contentType: Int64
    }

    private struct AnnotationRow {
        let pk: Int64
        let deleted: Int64?
        let assetID: String?
        let selected: String?
        let representative: String?
        let note: String?
    }

    private enum FixtureError: Error {
        case database
    }
}
