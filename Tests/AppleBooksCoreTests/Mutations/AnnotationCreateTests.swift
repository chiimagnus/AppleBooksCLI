import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationCreateTests")
struct AnnotationCreateTests {
    @Test
    func newHighlightCommitsOneNativeRecordAndPreservesCoreData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var projected: [Int64] = []
        let writer = fixture.writer { projected.append($0) }
        let result = try fixture.create(writer: writer, note: "A synthetic note.")
        #expect(result.committed && result.changed)
        #expect(result.localPK == 1)
        #expect(result.stableID != nil)
        #expect(result.warnings.isEmpty)
        #expect(projected == [1])
        #expect(try fixture.count() == 1)
        #expect(try fixture.scalar("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 1)
        let row = try #require(try fixture.row())
        #expect(row["Z_ENT"] == "17")
        #expect(row["Z_OPT"] == "1")
        #expect(row["ZANNOTATIONDELETED"] == "0")
        #expect(row["ZANNOTATIONTYPE"] == "2")
        #expect(row["ZANNOTATIONSTYLE"] == "1")
        #expect(row["ZANNOTATIONISUNDERLINE"] == "0")
        #expect(row["ZANNOTATIONSELECTEDTEXT"] == "token")
        #expect(row["ZANNOTATIONREPRESENTATIVETEXT"] == fixture.paragraph)
        #expect(row["ZANNOTATIONNOTE"] == "A synthetic note.")
        #expect(row["ZANNOTATIONLOCATION"] == fixture.selection.cfi)
        #expect(row["ZANNOTATIONUUID"] == result.stableID)
        #expect(row["ZANNOTATIONASSETID"] == "synthetic-asset")
        #expect(row["ZANNOTATIONCREATORIDENTIFIER"] == "com~apple~iBooks")
        #expect(try fixture.backupCount() == 1)
    }

    @Test
    func originalCreationTimeIsStoredOnFirstInsertWithoutReplacingNotesOrIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.writer { _ in }
        let app = try fixture.facade(annotationWriter: writer)
        let historical = Date(timeIntervalSince1970: 1_685_707_095.125)
        let created = try fixture.create(
            writer: writer, note: "Historical synthetic note", createdAt: historical
        )
        #expect(created.committed && created.changed && created.warnings.isEmpty)
        let uuid = try #require(created.stableID)
        let stored = try #require(try app.semanticAnnotation(uuid: uuid))
        #expect(stored.createdAt == historical)
        #expect(try #require(stored.modifiedAt) > historical)
        #expect(stored.note == "Historical synthetic note")
        #expect(stored.selectedText == "token")
        #expect(stored.uuid == uuid)
        let noOp = try fixture.create(
            writer: writer, note: "Historical synthetic note",
            createdAt: Date(timeIntervalSince1970: 1_685_707_000)
        )
        #expect(!noOp.changed && !noOp.committed)
        #expect(noOp.stableID == uuid)
        #expect(try app.semanticAnnotation(uuid: uuid)?.createdAt == historical)
        #expect(try fixture.backupCount() == 1)
        #expect(try fixture.count() == 1)
    }

    @Test
    func invalidOriginalCreationTimesRejectBeforeAnyWriteOrBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.writer { _ in Issue.record("Invalid date must not project") }
        for invalid in [
            Date(timeIntervalSinceNow: 3600),
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: 253_402_300_800),
        ] {
            #expect(throws: AnnotationWriteError.invalidCreationDate) {
                _ = try fixture.create(writer: writer, note: nil, createdAt: invalid)
            }
        }
        let app = try fixture.facade(annotationWriter: writer)
        let preview = try app.previewAnnotationBatch(
            assetID: "synthetic-asset", requests: [
                AnnotationCreationRequest(text: "token", createdAt: Date(timeIntervalSinceNow: 3600)),
            ]
        )
        #expect(throws: AnnotationWriteError.invalidCreationDate) { _ = try preview[0].get() }
        #expect(try fixture.count() == 0)
        #expect(try fixture.backupCount() == 0)
    }

    @Test
    func repeatedIdenticalRequestIsQuietNoOpWithoutBackupOrProjection() throws {
        let f = try Fixture()
        defer { f.remove() }
        var projections = 0
        let writer = f.writer { _ in projections += 1 }
        let first = try f.create(writer: writer, note: nil)
        let second = try f.create(writer: writer, note: nil)
        #expect(first.committed && first.changed)
        #expect(second.committed == false && second.changed == false)
        #expect(second.stableID == first.stableID)
        #expect(try f.count() == 1)
        #expect(try f.backupCount() == 1)
        #expect(projections == 1)
    }

    @Test
    func sameLocationDifferentStyleNoteAndTombstoneConflictBeforeBackup() throws {
        let f = try Fixture()
        defer { f.remove() }
        let writer = f.writer { _ in }
        _ = try f.create(writer: writer, note: "Original")
        let backups = try f.backupCount()
        for action in [
            { try f.create(writer: writer, note: "Different") },
            { try f.create(writer: writer, note: "Original", color: .blue) },
            { try f.create(writer: writer, note: nil) },
        ] {
            #expect(throws: AnnotationCreateError.conflict) { _ = try action() }
        }
        try f.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1")
        #expect(throws: AnnotationCreateError.conflict) {
            _ = try f.create(writer: writer, note: "Original")
        }
        #expect(try f.count() == 1)
        #expect(try f.backupCount() == backups)
    }

    @Test
    func missingExecutableVersionFailsBeforeLocalCommitOrBackup() throws {
        let f = try Fixture()
        defer { f.remove() }
        var validations = 0
        var projected = 0
        let creator = AnnotationCloudProjector(
            projectAction: { _ in projected += 1 },
            validateCreationTarget: { assetID in
                #expect(assetID == "synthetic-asset")
                validations += 1
                throw AnnotationCreateError.applicationVersionUnavailable
            }
        )
        let writer = AnnotationWriter(
            database: f.database, backupRoot: f.backupRoot,
            booksApp: .detached, creationProjector: creator
        )
        #expect(throws: AnnotationCreateError.applicationVersionUnavailable) {
            _ = try f.create(writer: writer, note: "Synthetic first highlight")
        }
        #expect(validations == 1)
        #expect(projected == 0)
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)
        #expect(try f.scalar("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 0)
    }

    @Test
    func noCreationProjectorOrSourceChangeNeverInserts() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(throws: AnnotationCreateError.projectionUnavailable) {
            _ = try f.create(writer: f.writerWithoutCreator(), note: nil)
        }
        let writer = f.writer { _ in }
        #expect(throws: AnnotationCreateError.sourceChanged) {
            _ = try writer.create(
                assetID: "synthetic-asset", selection: f.selection, note: nil, color: .green,
                verifySource: { throw AnnotationCreateError.sourceChanged }
            )
        }
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)
    }

    @Test
    func sourceModifiedBetweenSelectionAndWriteRejectsWithNoOrphan() throws {
        let f = try Fixture()
        defer { f.remove() }
        let writer = f.writer { _ in }
        try "<html><body><p id=\"test\">Entirely different chapter.</p></body></html>".write(
            to: f.chapter, atomically: true, encoding: .utf8
        )
        #expect(throws: EPUBAnnotationLocatorError.noMatch) {
            _ = try f.create(writer: writer, note: nil)
        }
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)
    }

    @Test
    func projectionFailureAfterCommitIsWarningAndDoesNotReinsert() throws {
        let f = try Fixture()
        defer { f.remove() }
        var projections = 0
        let writer = f.writer { _ in
            projections += 1
            throw AnnotationCloudProjectionError.bridgeRejected(99)
        }
        let first = try f.create(writer: writer, note: "Original")
        #expect(first.committed && first.changed)
        #expect(first.warnings == [.cloudProjectionFailed])
        let repeatRequest = try f.create(writer: writer, note: "Original")
        #expect(!repeatRequest.changed && !repeatRequest.committed)
        #expect(projections == 1)
        #expect(try f.count() == 1)
    }

    @Test
    func schemaDriftAndMutationAbortPreservePrimaryKeyAndNoCommittedRows() throws {
        let missing = try Fixture()
        defer { missing.remove() }
        try missing.execute("ALTER TABLE ZAEANNOTATION ADD COLUMN ZNEWREQUIRED TEXT NOT NULL DEFAULT ''")
        #expect(throws: WriteSchemaGuardError.unknownRequiredColumns(
            table: "ZAEANNOTATION", columns: ["ZNEWREQUIRED"]
        )) {
            _ = try missing.create(writer: missing.writer { _ in }, note: nil)
        }
        #expect(try missing.count() == 0)
        #expect(try missing.backupCount() == 0)
        let blocked = try Fixture()
        defer { blocked.remove() }
        try blocked.execute("""
            CREATE TRIGGER fail_creation BEFORE INSERT ON ZAEANNOTATION
            BEGIN SELECT RAISE(ABORT, 'synthetic write failed'); END;
            """)
        do {
            _ = try blocked.create(writer: blocked.writer { _ in }, note: nil)
            Issue.record("Expected failure before COMMIT")
        } catch let failure as MutationFailure {
            #expect(failure.code == .mutationFailed)
            #expect(!failure.committed)
        }
        #expect(try blocked.count() == 0)
        #expect(try blocked.scalar("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 0)
    }


    @Test
    func facadeResolvesRealBookAndReadsNewAnnotationThroughExistingQueries() throws {
        let f = try Fixture()
        defer { f.remove() }
        let app = try f.facade(annotationWriter: f.writer { _ in })
        let first = try app.createAnnotation(
            assetID: "synthetic-asset", text: "token", chapterOrder: 1,
            note: "Facade note", color: .yellow
        )
        #expect(first.committed && first.changed)
        let stored = try #require(first.stableID)
        let annotation = try #require(try app.semanticAnnotation(uuid: stored))
        #expect(annotation.selectedText == "token")
        #expect(annotation.note == "Facade note")
        #expect(annotation.style == AnnotationColor.yellow.rawValue)
        let repeatCall = try app.createAnnotation(
            assetID: "synthetic-asset", text: "token", chapterOrder: 1,
            note: "Facade note", color: .yellow
        )
        #expect(!repeatCall.changed && repeatCall.stableID == stored)
        #expect(try f.count() == 1)
    }

    @Test
    func batchPreflightDetectsSameRangeConflictsBeforeAnyWrite() throws {
        let f = try Fixture()
        defer { f.remove() }
        let app = try f.facade(annotationWriter: f.writer { _ in })
        let checks = try app.previewAnnotationBatch(assetID: "synthetic-asset", requests: [
            AnnotationCreationRequest(text: "token", chapterOrder: 1, note: "same", color: .green),
            AnnotationCreationRequest(text: "token", chapterOrder: 1, note: "same", color: .green),
            AnnotationCreationRequest(text: "token", chapterOrder: 1, note: "different", color: .green),
            AnnotationCreationRequest(text: "token", chapterOrder: 1, note: "same", color: .green),
            AnnotationCreationRequest(text: "absent", chapterOrder: 1),
            AnnotationCreationRequest(text: "synthetic", occurrence: 1),
        ])
        #expect(checks.count == 6)
        for index in 0..<4 {
            #expect(throws: AnnotationCreateError.conflict) { _ = try checks[index].get() }
        }
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try checks[4].get() }
        #expect(throws: EPUBAnnotationLocatorError.invalidOccurrence) { _ = try checks[5].get() }
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)
        let identical = try app.previewAnnotationBatch(assetID: "synthetic-asset", requests: [
            AnnotationCreationRequest(text: "token", chapterOrder: 1),
            AnnotationCreationRequest(text: "token", chapterOrder: 1),
        ])
        #expect(try identical[0].get().status == .ready)
        #expect(try identical[1].get().status == .ready)
        let dates = try app.previewAnnotationBatch(assetID: "synthetic-asset", requests: [
            AnnotationCreationRequest(text: "token", chapterOrder: 1, createdAt: Date(timeIntervalSince1970: 100)),
            AnnotationCreationRequest(text: "token", chapterOrder: 1, createdAt: Date(timeIntervalSince1970: 200)),
        ])
        #expect(throws: AnnotationCreateError.conflict) { _ = try dates[0].get() }
        #expect(throws: AnnotationCreateError.conflict) { _ = try dates[1].get() }
        #expect(try f.count() == 0)
    }

    @Test
    func previewIsReadOnlyBeforeAndAfterNativeCreation() throws {
        let f = try Fixture()
        defer { f.remove() }
        let app = try f.facade(annotationWriter: f.writer { _ in })
        let preview = try app.previewAnnotation(
            assetID: "synthetic-asset", text: "token", chapterOrder: 1, note: "test note"
        )
        #expect(preview.status == .ready)
        #expect(preview.existingUUID == nil)
        #expect(preview.chapterOrder == 1)
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)

        let created = try app.createAnnotation(
            assetID: "synthetic-asset", text: "token", chapterOrder: 1, note: "test note"
        )
        let after = try app.previewAnnotation(
            assetID: "synthetic-asset", text: "token", chapterOrder: 1, note: "test note"
        )
        #expect(after.status == .alreadyExists)
        #expect(after.existingUUID == created.stableID)
        #expect(try f.count() == 1)
        #expect(try f.backupCount() == 1)
        #expect(throws: AnnotationCreateError.conflict) {
            _ = try app.previewAnnotation(
                assetID: "synthetic-asset", text: "token", chapterOrder: 1, note: "different note"
            )
        }
        #expect(try f.backupCount() == 1)
    }

    @Test
    func facadeWithoutNativeCreateProjectorNeverCommits() throws {
        let f = try Fixture()
        defer { f.remove() }
        let app = try f.facade(annotationWriter: f.writerWithoutCreator())
        #expect(throws: AnnotationCreateError.projectionUnavailable) {
            _ = try app.createAnnotation(assetID: "synthetic-asset", text: "token")
        }
        #expect(try f.count() == 0)
        #expect(try f.backupCount() == 0)
    }


    @Test
    func underlineAndOtherNativeColorsPreserveStyleAndDoNotForceNotes() throws {
        let f = try Fixture()
        defer { f.remove() }
        let writer = f.writer { _ in }
        let created = try writer.create(
            assetID: "synthetic-asset", selection: f.selection, note: nil,
            color: .purple, underline: true,
            verifySource: { try EPUBAnnotationLocator(content: BookContent(root: f.epub)).locate("token") }
        )
        #expect(created.committed)
        let row = try #require(try f.row())
        #expect(row["ZANNOTATIONSTYLE"] == "5")
        #expect(row["ZANNOTATIONISUNDERLINE"] == "1")
        #expect(row["ZANNOTATIONNOTE"] == nil)
        #expect(try f.count() == 1)
    }

    @Test
    func repairAfterCommittedProjectionFailureReusesTheSameNativeUUID() throws {
        let f = try Fixture()
        defer { f.remove() }
        var attempts = 0
        let writer = f.writer { _ in
            attempts += 1
            if attempts == 1 { throw AnnotationCloudProjectionError.bridgeRejected(17) }
        }
        let created = try f.create(writer: writer, note: "Unsent synthetic note")
        #expect(created.committed && created.changed)
        #expect(created.warnings == [.cloudProjectionFailed])
        let uuid = try #require(created.stableID)
        let countBefore = try f.count()
        let backupBefore = try f.backupCount()
        let app = try f.facade(annotationWriter: writer)
        let repair = try app.repairAnnotationProjection(uuid: uuid)
        #expect(repair.verified)
        #expect(repair.annotationUUID == uuid)
        #expect(repair.warningCodes.isEmpty)
        #expect(attempts == 2)
        #expect(try f.count() == countBefore)
        #expect(try f.backupCount() == backupBefore)
        #expect(try app.semanticAnnotation(uuid: uuid)?.note == "Unsent synthetic note")
    }

    @Test
    func cloudRepairReprojectsOnlyExistingUUIDAndNeverInserts() throws {
        let f = try Fixture()
        defer { f.remove() }
        var projected: [Int64] = []
        let writer = f.writer { projected.append($0) }
        let created = try f.create(writer: writer, note: "Synthetic")
        let uuid = try #require(created.stableID)
        let originalBackups = try f.backupCount()
        let app = try f.facade(annotationWriter: writer)
        let repaired = try app.repairAnnotationProjection(uuid: uuid)
        #expect(repaired.verified)
        #expect(repaired.annotationUUID == uuid)
        #expect(repaired.warningCodes.isEmpty)
        #expect(projected == [created.localPK!, created.localPK!])
        #expect(try f.count() == 1)
        #expect(try f.backupCount() == originalBackups)
        #expect(throws: AnnotationWriteError.annotationMissing) {
            _ = try app.repairAnnotationProjection(uuid: "no-such-uuid")
        }
        try f.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1")
        #expect(throws: AnnotationWriteError.annotationNotWritable) {
            _ = try app.repairAnnotationProjection(uuid: uuid)
        }
        #expect(try f.count() == 1)
    }

    @Test
    func failedSourceRevalidationInsideTransactionRollsBackInsertedRowAndPrimaryKey() throws {
        let f = try Fixture()
        defer { f.remove() }
        var checks = 0
        let writer = f.writer { _ in }
        do {
            _ = try writer.create(
                assetID: "synthetic-asset", selection: f.selection,
                note: nil, color: .green,
                verifySource: {
                    checks += 1
                    guard checks >= 4 else { return f.selection }
                    return EPUBAnnotationSelection(
                        chapterOrder: f.selection.chapterOrder,
                        resourcePath: f.selection.resourcePath,
                        selectedText: "changed",
                        representativeText: f.selection.representativeText,
                        cfi: f.selection.cfi,
                        sourceGeneration: f.selection.sourceGeneration,
                        bookIdentity: f.selection.bookIdentity
                    )
                }
            )
            Issue.record("Expected failed source revalidation before COMMIT")
        } catch let failure as MutationFailure {
            #expect(failure.code == .invariantFailed)
            #expect(!failure.committed)
        }
        #expect(checks >= 4)
        #expect(try f.count() == 0)
        #expect(try f.scalar("SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 0)
    }

    @Test
    func sameLocationSystemBookmarkDoesNotBlockUserHighlight() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.execute("""
            INSERT INTO ZAEANNOTATION(
                Z_PK,Z_ENT,Z_OPT,ZANNOTATIONTYPE,ZANNOTATIONDELETED,
                ZANNOTATIONASSETID,ZANNOTATIONLOCATION
            ) VALUES(1,17,1,3,0,'synthetic-asset','\(f.selection.cfi)');
            UPDATE Z_PRIMARYKEY SET Z_MAX=1 WHERE Z_NAME='AEAnnotation';
            """)
        let added = try f.create(writer: f.writer { _ in }, note: nil)
        #expect(added.committed && added.localPK == 2)
        #expect(try f.count() == 2)
    }

    @Test
    func invalidNotesFailBeforeAnyWriteOrBackup() throws {
        let f = try Fixture()
        defer { f.remove() }
        for note in ["", " \n ", String(repeating: "x", count: 10_001)] {
            #expect(throws: AnnotationWriteError.invalidNoteLength) {
                _ = try f.create(writer: f.writer { _ in }, note: note)
            }
        }
        #expect(try f.backupCount() == 0)
        #expect(try f.count() == 0)
    }

    private final class Fixture {
        let root: URL
        let database: URL
        let library: URL
        let backupRoot: URL
        let epub: URL
        let chapter: URL
        let paragraph = "This synthetic sentence contains a token for highlighting."
        let selection: EPUBAnnotationSelection

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            backupRoot = root.appendingPathComponent("backups", isDirectory: true)
            database = root.appendingPathComponent("annotations.sqlite")
            library = root.appendingPathComponent("library.sqlite")
            epub = root.appendingPathComponent("synthetic.epub", isDirectory: true)
            chapter = epub.appendingPathComponent("OPS/chapter.xhtml")
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try """
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
                <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles></container>
                """.write(to: epub.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
            try """
                <package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                </manifest><spine><itemref idref="chapter"/></spine></package>
                """.write(to: epub.appendingPathComponent("OPS/content.opf"), atomically: true, encoding: .utf8)
            try "<html><head><title>Sample</title></head><body><p id=\"test\">\(paragraph)</p></body></html>".write(
                to: chapter, atomically: true, encoding: .utf8
            )
            selection = try EPUBAnnotationLocator(content: BookContent(root: epub)).locate("token")
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
                throw AnnotationWriteError.writeFailed
            }
            defer { sqlite3_close_v2(handle) }
            let sql = """
                CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
                INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,0);
                CREATE TABLE ZAEANNOTATION(
                  Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZANNOTATIONDELETED INTEGER,
                  ZANNOTATIONISUNDERLINE INTEGER,ZANNOTATIONSTYLE INTEGER,ZANNOTATIONTYPE INTEGER,
                  ZPLABSOLUTEPHYSICALLOCATION INTEGER,ZPLLOCATIONRANGESTART INTEGER,ZPLLOCATIONRANGEEND INTEGER,
                  ZANNOTATIONCREATIONDATE REAL,ZANNOTATIONMODIFICATIONDATE REAL,
                  ZANNOTATIONASSETID TEXT,ZANNOTATIONCREATORIDENTIFIER TEXT,ZANNOTATIONLOCATION TEXT,
                  ZANNOTATIONNOTE TEXT,ZANNOTATIONREPRESENTATIVETEXT TEXT,ZANNOTATIONSELECTEDTEXT TEXT,
                  ZANNOTATIONUUID TEXT,ZFUTUREPROOFING11 TEXT,ZFUTUREPROOFING6 TEXT
                );
                """
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw AnnotationWriteError.writeFailed
            }
            var libraryHandle: OpaquePointer?
            guard sqlite3_open(library.path, &libraryHandle) == SQLITE_OK, let libraryHandle else {
                throw AnnotationWriteError.writeFailed
            }
            defer { sqlite3_close_v2(libraryHandle) }
            guard sqlite3_exec(libraryHandle, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER,ZTITLE TEXT,ZAUTHOR TEXT)", nil, nil, nil) == SQLITE_OK else {
                throw AnnotationWriteError.writeFailed
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(libraryHandle, "INSERT INTO ZBKLIBRARYASSET VALUES(1,?,?,1,'Synthetic','Fixture')", -1, &statement, nil) == SQLITE_OK, let statement else {
                throw AnnotationWriteError.writeFailed
            }
            defer { sqlite3_finalize(statement) }
            guard bindSQLiteText("synthetic-asset", to: statement, at: 1) == SQLITE_OK,
                  bindSQLiteText(epub.path, to: statement, at: 2) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw AnnotationWriteError.writeFailed
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func facade(annotationWriter: AnnotationWriter) throws -> AppleBooks {
            try AppleBooks(
                libraryDB: library, annotationsDB: database, configurationFile: nil,
                collectionWriter: CollectionWriter(database: library, booksApp: .detached),
                annotationWriter: annotationWriter, libraryBackupRoot: backupRoot
            )
        }
        func writer(_ project: @escaping (Int64) throws -> Void) -> AnnotationWriter {
            AnnotationWriter(
                database: database, backupRoot: backupRoot,
                booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}, sleep: { _ in }),
                creationProjector: AnnotationCloudProjector(projectAction: project)
            )
        }
        func writerWithoutCreator() -> AnnotationWriter {
            AnnotationWriter(
                database: database, backupRoot: backupRoot,
                booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}, sleep: { _ in })
            )
        }
        func create(
            writer: AnnotationWriter, note: String?, color: AnnotationColor = .green,
            createdAt: Date? = nil
        ) throws -> MutationResult {
            try writer.create(
                assetID: "synthetic-asset", selection: selection, note: note,
                color: color, createdAt: createdAt, verifySource: {
                    try EPUBAnnotationLocator(content: BookContent(root: self.epub)).locate("token")
                }
            )
        }
        func execute(_ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else { throw AnnotationWriteError.writeFailed }
            defer { sqlite3_close_v2(db) }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AnnotationWriteError.writeFailed }
        }
        func scalar(_ sql: String) throws -> Int64 {
            let db = try SQLiteConnection.readOnly(path: database.path)
            defer { try? db.close() }
            let statement = try db.prepare(sql)
            guard try statement.step() else { throw AnnotationWriteError.writeFailed }
            return sqlite3_column_int64(statement.handle, 0)
        }
        func count() throws -> Int64 { try scalar("SELECT COUNT(*) FROM ZAEANNOTATION") }
        func backupCount() throws -> Int {
            guard FileManager.default.fileExists(atPath: backupRoot.path) else { return 0 }
            return try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).filter {
                BackupMetadata.parse(filename: $0, sourceStem: "annotations") != nil
            }.count
        }
        func row() throws -> [String: String?]? {
            let db = try SQLiteConnection.readOnly(path: database.path)
            defer { try? db.close() }
            let statement = try db.prepare("SELECT * FROM ZAEANNOTATION ORDER BY Z_PK LIMIT 2")
            guard try statement.step() else { return nil }
            var result: [String: String?] = [:]
            let handle = try #require(statement.handle)
            for index in 0..<sqlite3_column_count(handle) {
                let name = String(cString: sqlite3_column_name(handle, index))
                switch sqlite3_column_type(handle, index) {
                case SQLITE_INTEGER: result[name] = String(sqlite3_column_int64(handle, index))
                case SQLITE_TEXT: result[name] = try decodeSQLiteText(handle, at: index)
                case SQLITE_NULL: result[name] = nil
                default: break
                }
            }
            guard try !statement.step() else { throw AnnotationWriteError.writeFailed }
            return result
        }
    }
}
