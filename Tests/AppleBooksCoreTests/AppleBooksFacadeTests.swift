import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AppleBooksFacadeTests")
struct AppleBooksFacadeTests {
    @Test
    func exposesOnlyThePlannedReadSemantics() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config
        )

        #expect(try books.semanticCollectionSummaryPage(limit: 100).items.map(\.localPK) == [1])
        #expect(try books.semanticCollection(localPK: 1)?.title == "Shelf")
        #expect(try books.semanticCollectionSummaryPage(matchingTitle: "helf", limit: 100).items.map(\.localPK) == [1])
        #expect(try books.bookSummaryPage(limit: 100).items.map(\.localPK) == [1, 2, 3])
        #expect(try books.semanticBookDetail(localPK: 1)?.assetID == "asset-a")
        #expect(try books.searchBookSummaries("alpha", field: .title).items.map(\.localPK) == [1])
        #expect(try books.searchBookSummaries("Fic", field: .genre).items.map(\.localPK) == [1, 2])

        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(limit: 100)).items.map(\.localPK) == [10])
        #expect(try books.semanticAnnotation(localPK: 11) == nil)
        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(color: .yellow, limit: 100)).items.map(\.localPK) == [10])
        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(text: "quote", textField: .highlight, limit: 100)).items.map(\.localPK) == [10])
        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(text: "note", textField: .note, limit: 100)).items.map(\.localPK) == [10])
        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(text: "representative", limit: 100)).items.map(\.localPK) == [10])
        let lower = try #require(CoreDataTime.date(from: 50))
        let upper = try #require(CoreDataTime.date(from: 150))
        #expect(try books.semanticAnnotationPage(AnnotationQueryRequest(createdAfter: lower, createdBefore: upper, limit: 100)).items.map(\.localPK) == [10])

    }

    @Test
    func repeatedLocalAnnotationMutationsStayPendingUntilOneExplicitRootSync() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var events: [String] = []
        var running = false
        var annotationPending = 0
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { events.append("terminate"); running = false; return true },
            launch: { events.append("launch"); running = true; annotationPending = 0 },
            sleep: { _ in }
        )
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config,
            collectionWriter: CollectionWriter(
                database: fixture.library,
                booksApp: controller,
                cloudSynchronizer: CollectionCloudSynchronizer(
                    booksApp: controller,
                    detailState: { _ in nil },
                    memberState: { _, _ in nil },
                    deletedMemberStates: { _ in [] },
                    pendingCount: { 0 },
                    recycleAction: { events.append("recycle") }
                )
            ),
            annotationWriter: AnnotationWriter(
                database: fixture.annotations,
                booksApp: controller,
                cloudProjector: AnnotationCloudProjector { _ in
                    events.append("projectAnnotation")
                    annotationPending = 1
                },
                cloudSynchronizer: AnnotationCloudSynchronizer(
                    booksApp: controller,
                    stateAction: { _ in nil },
                    pendingCount: { annotationPending }
                )
            )
        )

        let first = try books.updateAnnotationNote(uuid: "uuid-user", note: "batch one")
        let second = try books.updateAnnotationNote(uuid: "uuid-user", note: "batch two")
        #expect(first.warnings.isEmpty)
        #expect(second.warnings.isEmpty)
        #expect(running == false)
        #expect(events == ["projectAnnotation", "projectAnnotation"])

        let summary = try books.syncPendingCloudChanges()

        #expect(summary == CloudSyncSummary(collectionPendingBefore: 0, annotationPendingBefore: 1))
        #expect(events == ["projectAnnotation", "projectAnnotation", "launch"])
    }

    @Test
    func annotationOnlyPendingCloudSyncRestartsRunningBooksOnce() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var events: [String] = []
        var running = true
        var annotationPending = 1
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { events.append("terminate"); running = false; return true },
            launch: { events.append("launch"); running = true; annotationPending = 0 },
            sleep: { _ in }
        )
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config,
            collectionWriter: CollectionWriter(
                database: fixture.library,
                booksApp: controller,
                cloudSynchronizer: CollectionCloudSynchronizer(
                    booksApp: controller,
                    detailState: { _ in nil },
                    memberState: { _, _ in nil },
                    deletedMemberStates: { _ in [] },
                    pendingCount: { 0 },
                    recycleAction: { events.append("recycle") }
                )
            ),
            annotationWriter: AnnotationWriter(
                database: fixture.annotations,
                booksApp: controller,
                cloudSynchronizer: AnnotationCloudSynchronizer(
                    booksApp: controller,
                    stateAction: { _ in nil },
                    pendingCount: { annotationPending }
                )
            )
        )

        let summary = try books.syncPendingCloudChanges()

        #expect(summary == CloudSyncSummary(collectionPendingBefore: 0, annotationPendingBefore: 1))
        #expect(events == ["terminate", "launch"])
    }

    @Test
    func explicitAnnotationSyncUsesDeeplinkAndRestoresOriginallyClosedBooks() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute(fixture.annotations, "UPDATE ZAEANNOTATION SET ZANNOTATIONLOCATION='epubcfi(/6/8[ch]!/4/2,:1,:2)' WHERE Z_PK=10")

        var running = false
        var events: [String] = []
        var stateReads = 0
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { events.append("terminate"); running = false; return true },
            launch: { events.append("launch"); running = true },
            launchWithoutActivation: { events.append("launchWithoutActivation"); running = true },
            sleep: { _ in }
        )
        let writer = AnnotationWriter(
            database: fixture.annotations,
            backupRoot: fixture.root.appendingPathComponent("annotation-backups"),
            booksApp: controller,
            cloudProjector: AnnotationCloudProjector { localPK in
                #expect(localPK == 10)
                events.append("project")
            },
            cloudSynchronizer: AnnotationCloudSynchronizer(
                booksApp: controller,
                stateAction: { localPK in
                    #expect(localPK == 10)
                    defer { stateReads += 1 }
                    return stateReads == 0
                        ? .init(editGeneration: 2, syncGeneration: 1, systemFieldsBytes: 10)
                        : .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 10)
                },
                maxPollCount: 2
            )
        )
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config,
            collectionWriter: CollectionWriter(database: fixture.library, booksApp: controller),
            annotationWriter: writer
        )

        let result = try books.updateAnnotationNote(uuid: "uuid-user", note: "explicit sync", syncCloud: true)

        #expect(result.warnings.isEmpty)
        #expect(result.appleBooksURL?.hasPrefix("ibooks://assetid/asset-a#epubcfi") == true)
        #expect(events == ["project", "launchWithoutActivation", "terminate"])
        #expect(running == false)
    }

    @Test
    func annotationMutationWithoutExplicitSyncOnlyProjectsLocally() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var events: [String] = []
        let controller = BooksAppController(
            isRunning: { false },
            terminate: { events.append("terminate"); return true },
            launch: { events.append("launch") },
            launchWithoutActivation: { events.append("launchWithoutActivation") },
            sleep: { _ in }
        )
        let writer = AnnotationWriter(
            database: fixture.annotations,
            backupRoot: fixture.root.appendingPathComponent("annotation-backups"),
            booksApp: controller,
            cloudProjector: AnnotationCloudProjector { _ in events.append("project") },
            cloudSynchronizer: AnnotationCloudSynchronizer(
                booksApp: controller,
                stateAction: { _ in .init(editGeneration: 2, syncGeneration: 1, systemFieldsBytes: 10) },
                maxPollCount: 1
            )
        )
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config,
            collectionWriter: CollectionWriter(database: fixture.library, booksApp: controller),
            annotationWriter: writer
        )

        let result = try books.updateAnnotationNote(localPK: 10, note: "offline-default")

        #expect(result.warnings.isEmpty)
        #expect(events == ["project"])
    }

    @Test
    func semanticCurrentChapterFailsClosedWhenBookAssetIdColumnIsMissing() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);
        INSERT INTO ZBKLIBRARYASSET VALUES (1);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT
        );
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let books = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .books,
            columns: ["ZASSETID"]
        )) {
            _ = try books.semanticCurrentReadingChapter(forBookLocalPK: 1)
        }
    }

    private func fixture() throws -> Fixture {
        let root = temporaryDirectory()
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZGENRE TEXT,
          ZISFINISHED INTEGER,
          ZREADINGPROGRESS REAL,
          ZDATEFINISHED REAL,
          ZLASTOPENDATE REAL
        );
        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          ZTITLE TEXT,
          ZDELETEDFLAG INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'asset-a','Alpha','Fiction',0,0.5,NULL,100),
          (2,'asset-b','Beta','Fiction',1,0,200,200),
          (3,NULL,'Gamma','Other',0,NULL,NULL,NULL);
        INSERT INTO ZBKCOLLECTION VALUES (1,'Shelf',0),(2,'Deleted',1);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,99);
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          Z_ENT INTEGER DEFAULT 17,
          Z_OPT INTEGER DEFAULT 1,
          ZANNOTATIONUUID TEXT,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONSTYLE INTEGER,
          ZANNOTATIONCREATIONDATE REAL,
          ZANNOTATIONMODIFICATIONDATE REAL,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONREPRESENTATIVETEXT TEXT,
          ZANNOTATIONNOTE TEXT,
          ZANNOTATIONLOCATION TEXT,
          ZFUTUREPROOFING6 TEXT DEFAULT '1'
        );
        INSERT INTO ZAEANNOTATION(
          Z_PK,ZANNOTATIONUUID,ZANNOTATIONASSETID,ZANNOTATIONDELETED,ZANNOTATIONTYPE,
          ZANNOTATIONSTYLE,ZANNOTATIONCREATIONDATE,ZANNOTATIONMODIFICATIONDATE,
          ZANNOTATIONSELECTEDTEXT,ZANNOTATIONREPRESENTATIVETEXT,ZANNOTATIONNOTE,ZANNOTATIONLOCATION
        ) VALUES
          (10,'uuid-user','asset-a',0,1,3,100,150,'quote','representative','note',NULL),
          (11,'uuid-position','asset-a',0,3,0,110,160,'','','','epubcfi(/6/8[current]!/4/2,:1,:1)'),
          (12,'uuid-deleted','asset-a',1,1,3,120,170,'deleted','','',NULL);
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return Fixture(root: root, library: library, annotations: annotations, config: config)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(_ databaseURL: URL, _ sql: String) throws {
        var database: OpaquePointer?
        let open = sqlite3_open(databaseURL.path, &database)
        guard open == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: open, handle: database)
        }
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
    }

    private func database(at url: URL, sql: String) throws -> URL {
        var database: OpaquePointer?
        let open = sqlite3_open(url.path, &database)
        guard open == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: open, handle: database)
        }
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
        return url
    }

    private struct Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
    }
}
