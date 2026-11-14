import AppleBooksCloudBridge
import Foundation
import SQLite3
import XCTest
@testable import AppleBooksCore

// Explicit opt-in only: writes a new native annotation to a separately imported synthetic EPUB.
final class AnnotationCreateFeasibilityLiveTests: XCTestCase {
    private struct Sample {
        let title: String
        let selected: String
        let paragraph: String
        let cfi: String
        let note: String

        static func named(_ value: String) -> Sample? {
            switch value {
            case "A":
                Sample(
                    title: "AppleBooksCLI P1T1 Synthetic A 20261114",
                    selected: "reserved",
                    paragraph: "This sentence is reserved for the code-created highlight.",
                    cfi: "epubcfi(/6/2[chapter]!/4/10[line4]/1,:17,:25)",
                    note: "Programmatic P1T1 note."
                )
            case "B":
                Sample(
                    title: "AppleBooksCLI P1T1 Synthetic B 20261114",
                    selected: "paper",
                    paragraph: "A distant paper kite crossed the empty courtyard.",
                    cfi: "epubcfi(/6/2[chapter]!/4/4[line1]/1,:10,:15)",
                    note: "Programmatic P1T1 first-book note."
                )
            default:
                nil
            }
        }
    }

    private struct Created {
        let localPK: Int64
        let uuid: String
    }

    func testProgrammaticallyCreatesSyntheticAnnotationUsingGuardedNativeRail() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["APPLEBOOKSCLI_P1T1_ALLOW_LIVE"] == "YES",
              let assetID = environment["APPLEBOOKSCLI_P1T1_ASSET_ID"],
              let sample = environment["APPLEBOOKSCLI_P1T1_CASE"].flatMap(Sample.named) else {
            throw XCTSkip("Explicit synthetic-book native-write opt-in required")
        }

        let discovered = try DatabaseDiscovery().discover()
        let library = try SQLiteConnection.readOnly(path: discovered.libraryDB.path)
        defer { try? library.close() }
        let bookQueries = BookQueries(connection: library)
        let target = try XCTUnwrap(bookQueries.uniqueResourceTarget(assetID: assetID))
        XCTAssertNotNil(target.path)
        try validateSyntheticBook(library, assetID: assetID, sample: sample)
        let source = EPUBSourceResolver.resolve(for: target, configuration: .empty)
        XCTAssertEqual(source.selectedSource, .current)
        let (_, reader) = try source.requireReader()
        let content = try BookContent(reader: reader)
        let firstChapter = try XCTUnwrap(content.listChapters().first)
        XCTAssertTrue(try content.getChapter(firstChapter.id).contains(sample.paragraph))

        let projector = try XCTUnwrap(AnnotationCloudProjector.live(
            annotationsDatabase: discovered.annotationsDB,
            bridgeAction: { root, cloudDB, annotationsDB, identity in
                root.path.withCString { rootPath in
                    cloudDB.path.withCString { cloudPath in
                        annotationsDB.path.withCString { annotationsPath in
                            withCloudBridgeUTF8Bytes(identity.assetID) { asset, assetLength in
                                withCloudBridgeUTF8Bytes(identity.uuid) { uuid, uuidLength in
                                    let status = ABTestAppendSyntheticAnnotationState(
                                        rootPath, cloudPath, annotationsPath,
                                        asset, assetLength, uuid, uuidLength
                                    )
                                    print("P1T1 native cloud bridge status: \(status)")
                                    return status
                                }
                            }
                        }
                    }
                }
            }
        ))
        if environment["APPLEBOOKSCLI_P1T1_RECOVER_ONLY"] == "YES" {
            let existing = try Self.existingSyntheticRow(
                discovered.annotationsDB, assetID: assetID, selected: sample.selected
            )
            try projector.project(localPK: existing.localPK)
            print("P1T1 repaired existing synthetic UUID without another local INSERT")
            return
        }
        let uuid = UUID().uuidString
        let timestamp = Date().timeIntervalSinceReferenceDate
        let coordinator = MutationCoordinator(database: discovered.annotationsDB, booksApp: .live)
        let result = try coordinator.perform(
            preflight: { connection in
                try Self.requireSchema(connection.handle)
                try Self.assertNotCreated(connection.handle, assetID: assetID, selected: sample.selected)
            },
            revalidate: { handle in
                try Self.requireSchema(handle)
                try Self.assertNotCreated(handle, assetID: assetID, selected: sample.selected)
            },
            mutation: { handle in
                let allocated = try CoreDataPrimaryKey.allocate(
                    entityName: "AEAnnotation", table: .annotations, on: handle
                )
                try Self.insertSyntheticRow(
                    handle: handle, pk: allocated.localPK, entityID: allocated.entityID,
                    assetID: assetID, uuid: uuid, sample: sample, time: timestamp
                )
                return Created(localPK: allocated.localPK, uuid: uuid)
            },
            invariant: { handle, created in
                try Self.assertCreated(handle, assetID: assetID, uuid: created.uuid, sample: sample)
            },
            domainData: { created in
                MutationDomainData(localPK: created.localPK, stableID: created.uuid)
            },
            cloudProjection: { created in
                try projector.project(localPK: created.localPK)
            },
            readBack: { connection, created in
                try Self.assertCreated(connection.handle, assetID: assetID, uuid: created.uuid, sample: sample)
            }
        )
        XCTAssertTrue(result.committed)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.stableID, uuid)
        XCTAssertTrue(result.warnings.isEmpty, "Native projection and read-back must both succeed")
        print("P1T1 synthetic new local annotation committed; warnings=\(result.warnings.map(\.rawValue))")
    }

    private func validateSyntheticBook(_ connection: SQLiteConnection, assetID: String, sample: Sample) throws {
        let statement = try connection.prepare("""
            SELECT ZTITLE, ZAUTHOR FROM ZBKLIBRARYASSET
            WHERE ZASSETID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { throw ProbeError.invalidBook }
        let row = try SQLiteRow(statement: statement)
        guard try row.text("ZTITLE") == sample.title,
              try row.text("ZAUTHOR") == "AppleBooksCLI Test Fixture",
              try statement.step() == false else {
            throw ProbeError.invalidBook
        }
    }

    private static let columns: Set<String> = [
        "Z_PK", "Z_ENT", "Z_OPT", "ZANNOTATIONDELETED", "ZANNOTATIONISUNDERLINE",
        "ZANNOTATIONSTYLE", "ZANNOTATIONTYPE", "ZPLABSOLUTEPHYSICALLOCATION",
        "ZPLLOCATIONRANGESTART", "ZPLLOCATIONRANGEEND", "ZANNOTATIONCREATIONDATE",
        "ZANNOTATIONMODIFICATIONDATE", "ZANNOTATIONASSETID", "ZANNOTATIONCREATORIDENTIFIER",
        "ZANNOTATIONLOCATION", "ZANNOTATIONNOTE", "ZANNOTATIONREPRESENTATIVETEXT",
        "ZANNOTATIONSELECTEDTEXT", "ZANNOTATIONUUID", "ZFUTUREPROOFING11", "ZFUTUREPROOFING6",
    ]

    private static func existingSyntheticRow(
        _ database: URL, assetID: String, selected: String
    ) throws -> Created {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT Z_PK,ZANNOTATIONUUID FROM ZAEANNOTATION
            WHERE ZANNOTATIONASSETID=? AND ZANNOTATIONSELECTEDTEXT=? AND
                  ZANNOTATIONDELETED=0 AND ZANNOTATIONTYPE=2
            ORDER BY Z_PK LIMIT 2
            """)
        try statement.bind(assetID, at: 1)
        try statement.bind(selected, at: 2)
        guard try statement.step() else { throw ProbeError.missingReadBack }
        let row = try SQLiteRow(statement: statement)
        let pk = try XCTUnwrap(row.int64("Z_PK"))
        let uuid = try XCTUnwrap(row.text("ZANNOTATIONUUID"))
        guard try statement.step() == false else { throw ProbeError.alreadyExists }
        return Created(localPK: pk, uuid: uuid)
    }

    private static func requireSchema(_ handle: OpaquePointer?) throws {
        let handle = try XCTUnwrap(handle)
        try WriteSchemaGuard.validateTable(.annotations, required: columns, inserting: false, on: handle)
        _ = try WriteSchemaGuard.entity(named: "AEAnnotation", on: handle)
    }

    private static func assertNotCreated(_ handle: OpaquePointer?, assetID: String, selected: String) throws {
        let statement = try prepare(handle, """
            SELECT Z_PK FROM ZAEANNOTATION
            WHERE ZANNOTATIONASSETID=? AND ZANNOTATIONSELECTEDTEXT=?
            ORDER BY Z_PK LIMIT 2
            """)
        defer { sqlite3_finalize(statement) }
        guard bindSQLiteText(assetID, to: statement, at: 1) == SQLITE_OK,
              bindSQLiteText(selected, to: statement, at: 2) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw ProbeError.alreadyExists }
    }

    private static func insertSyntheticRow(
        handle: OpaquePointer, pk: Int64, entityID: Int64,
        assetID: String, uuid: String, sample: Sample, time: Double
    ) throws {
        let statement = try prepare(handle, """
            INSERT INTO ZAEANNOTATION(
              Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONISUNDERLINE,
              ZANNOTATIONSTYLE,ZANNOTATIONTYPE,ZPLABSOLUTEPHYSICALLOCATION,
              ZPLLOCATIONRANGESTART,ZPLLOCATIONRANGEEND,
              ZANNOTATIONCREATIONDATE,ZANNOTATIONMODIFICATIONDATE,
              ZANNOTATIONASSETID,ZANNOTATIONCREATORIDENTIFIER,ZANNOTATIONLOCATION,
              ZANNOTATIONNOTE,ZANNOTATIONREPRESENTATIVETEXT,ZANNOTATIONSELECTEDTEXT,
              ZANNOTATIONUUID,ZFUTUREPROOFING11,ZFUTUREPROOFING6
            ) VALUES(?, ?, 1, 0, 0, 1, 2, 0, 0, 0, ?, ?, ?,
                     'com~apple~iBooks', ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, pk) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, entityID) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, time) == SQLITE_OK,
              sqlite3_bind_double(statement, 4, time) == SQLITE_OK,
              bindSQLiteText(assetID, to: statement, at: 5) == SQLITE_OK,
              bindSQLiteText(sample.cfi, to: statement, at: 6) == SQLITE_OK,
              bindSQLiteText(sample.note, to: statement, at: 7) == SQLITE_OK,
              bindSQLiteText(sample.paragraph, to: statement, at: 8) == SQLITE_OK,
              bindSQLiteText(sample.selected, to: statement, at: 9) == SQLITE_OK,
              bindSQLiteText(uuid, to: statement, at: 10) == SQLITE_OK,
              bindSQLiteText(String(time), to: statement, at: 11) == SQLITE_OK,
              bindSQLiteText(String(time), to: statement, at: 12) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else { throw ProbeError.databaseWrite }
    }

    private static func assertCreated(
        _ handle: OpaquePointer?, assetID: String, uuid: String, sample: Sample
    ) throws {
        let statement = try prepare(handle, """
            SELECT ZANNOTATIONSELECTEDTEXT,ZANNOTATIONNOTE,ZANNOTATIONLOCATION,
                   ZANNOTATIONREPRESENTATIVETEXT,ZANNOTATIONTYPE,ZANNOTATIONDELETED
            FROM ZAEANNOTATION WHERE ZANNOTATIONASSETID=? AND ZANNOTATIONUUID=?
            ORDER BY Z_PK LIMIT 2
            """)
        defer { sqlite3_finalize(statement) }
        guard bindSQLiteText(assetID, to: statement, at: 1) == SQLITE_OK,
              bindSQLiteText(uuid, to: statement, at: 2) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw ProbeError.missingReadBack }
        let row = (try decodeSQLiteText(statement, at: 0), try decodeSQLiteText(statement, at: 1),
                   try decodeSQLiteText(statement, at: 2), try decodeSQLiteText(statement, at: 3))
        guard row.0 == sample.selected, row.1 == sample.note, row.2 == sample.cfi,
              row.3 == sample.paragraph, sqlite3_column_int(statement, 4) == 2,
              sqlite3_column_int(statement, 5) == 0,
              sqlite3_step(statement) == SQLITE_DONE else { throw ProbeError.missingReadBack }
    }

    private static func prepare(_ handle: OpaquePointer?, _ query: String) throws -> OpaquePointer {
        guard let handle else { throw ProbeError.databaseWrite }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, query, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ProbeError.databaseWrite
        }
        return statement
    }

    private enum ProbeError: Error {
        case invalidBook, alreadyExists, databaseWrite, missingReadBack
    }
}
