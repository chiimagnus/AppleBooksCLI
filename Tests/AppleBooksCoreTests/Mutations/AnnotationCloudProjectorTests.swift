import AppleBooksCloudBridge
import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@_silgen_name("ABUpdateExistingAnnotationCloudObject")
private func updateExistingAnnotationCloudObject(
    _ cloudObject: UnsafeMutableRawPointer?,
    _ row: UnsafeMutableRawPointer?
) -> Int8

@_silgen_name("ABTestUpdateExistingAnnotationCloudObjectWithBookClass")
private func testUpdateExistingAnnotationCloudObjectWithBookClass(
    _ cloudObject: UnsafeMutableRawPointer?,
    _ row: UnsafeMutableRawPointer?,
    _ bookClass: AnyClass
) -> Int8

@Suite("AnnotationCloudProjectorTests")
struct AnnotationCloudProjectorTests {
    @Test
    func liveProjectorResolvesExactAssetAndUUIDAfterBackup() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.annotationsDirectory, withIntermediateDirectories: true)
        let annotations = paths.annotationsDirectory.appendingPathComponent("AEAnnotation-test.sqlite")
        try execute(annotations, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT); INSERT INTO ZAEANNOTATION VALUES(7,'ASSET','UUID')")

        var events: [String] = []
        let projector = try #require(AnnotationCloudProjector.live(
            annotationsDatabase: annotations,
            homeDirectory: root,
            backupRoot: root.appendingPathComponent("backups", isDirectory: true),
            backupAction: { source, backupRoot in
                events.append("backup")
                #expect(source.path.hasSuffix("BCAssetData/BCAssetData"))
                #expect(backupRoot.lastPathComponent == "backups")
            },
            bridgeAction: { cloudRoot, database, passedAnnotations, identity in
                events.append("bridge")
                #expect(passedAnnotations == annotations)
                #expect(cloudRoot.path.hasSuffix("BCCloudData-iBooks"))
                #expect(database.path.hasSuffix("BCAssetData/BCAssetData"))
                #expect(identity == .init(assetID: "ASSET", uuid: "UUID"))
                return 0
            }
        ))

        try projector.project(localPK: 7)
        #expect(events == ["backup", "bridge"])
    }

    @Test
    func identityPreservesEmbeddedNULAtBudgetAndRejectsOversizeBeforePayloadMaterialization() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let acceptedDatabase = root.appendingPathComponent("annotations-accepted.sqlite")
        try execute(acceptedDatabase, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT)")
        let acceptedAssetID = String(repeating: "a", count: CloudProjectionResourcePolicy.stableIdentityBytes - 5) + "\0tail"
        try insertIdentity(acceptedDatabase, assetID: acceptedAssetID, uuid: "uuid\0tail")

        let identity = try AnnotationCloudProjector.identity(annotationsDatabase: acceptedDatabase, localPK: 7)
        #expect(identity == .init(assetID: acceptedAssetID, uuid: "uuid\0tail"))
        #expect(identity.assetID.utf8.count == CloudProjectionResourcePolicy.stableIdentityBytes)

        let oversizedDatabase = root.appendingPathComponent("annotations-oversized.sqlite")
        try execute(oversizedDatabase, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT)")
        try insertIdentity(
            oversizedDatabase,
            assetID: String(repeating: "b", count: CloudProjectionResourcePolicy.stableIdentityBytes + 1),
            uuid: "UUID"
        )
        #expect(throws: AnnotationCloudProjectionError.identityUnavailable) {
            _ = try AnnotationCloudProjector.identity(annotationsDatabase: oversizedDatabase, localPK: 7)
        }
    }

    @Test
    func bridgeUsesExactLengthForDatabaseIdentityLookup() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let cloudDatabase = storeDirectory.appendingPathComponent("BCAssetData")
        try Data().write(to: cloudDatabase)
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try execute(annotations, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONNOTE TEXT,
              ZFUTUREPROOFING6 TEXT,
              ZANNOTATIONTYPE INTEGER
            )
            """)
        try insertBridgeTarget(annotations, assetID: "asset\0tail", uuid: "uuid\0tail")

        let status = root.path.withCString { rootPath in
            cloudDatabase.path.withCString { cloudPath in
                annotations.path.withCString { annotationsPath in
                    withCloudBridgeUTF8Bytes("asset\0tail") { assetID, assetIDLength in
                        withCloudBridgeUTF8Bytes("uuid\0tail") { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                cloudPath,
                                annotationsPath,
                                assetID,
                                assetIDLength,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
        #expect(status >= 4)
    }

    @Test
    func bridgeRejectsInvalidUTF8AnnotationPayloadBeforePrivateFrameworkAccess() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let cloudDatabase = storeDirectory.appendingPathComponent("BCAssetData")
        try Data().write(to: cloudDatabase)
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try execute(annotations, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONNOTE TEXT,
              ZFUTUREPROOFING6 TEXT,
              ZANNOTATIONTYPE INTEGER
            );
            INSERT INTO ZAEANNOTATION VALUES(
              7,'asset-safe','uuid-safe',0,1,CAST(X'736563726574FF' AS TEXT),NULL,1
            );
            """)

        let status = root.path.withCString { rootPath in
            cloudDatabase.path.withCString { cloudPath in
                annotations.path.withCString { annotationsPath in
                    withCloudBridgeUTF8Bytes("asset-safe") { assetID, assetIDLength in
                        withCloudBridgeUTF8Bytes("uuid-safe") { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                cloudPath,
                                annotationsPath,
                                assetID,
                                assetIDLength,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
        #expect(status == 3)
    }

    @Test
    func bridgeBoundsAnnotationBodiesButDeletedRowsSkipLegacyNote() throws {
        let noteLimit = CloudProjectionResourcePolicy.annotationNoteBytes
        let metadataLimit = CloudProjectionResourcePolicy.fixedMetadataBytes

        #expect(try annotationBridgeStatus(
            deleted: false,
            noteSQL: "CAST(zeroblob(\(noteLimit)) AS TEXT)",
            fp6SQL: "NULL"
        ) >= 4)
        #expect(try annotationBridgeStatus(
            deleted: false,
            noteSQL: "CAST(zeroblob(\(noteLimit + 1)) AS TEXT)",
            fp6SQL: "NULL"
        ) == 3)
        #expect(try annotationBridgeStatus(
            deleted: false,
            noteSQL: "NULL",
            fp6SQL: "CAST(zeroblob(\(metadataLimit)) AS TEXT)"
        ) >= 4)
        #expect(try annotationBridgeStatus(
            deleted: false,
            noteSQL: "NULL",
            fp6SQL: "CAST(zeroblob(\(metadataLimit + 1)) AS TEXT)"
        ) == 3)
        #expect(try annotationBridgeStatus(
            deleted: true,
            noteSQL: "CAST(zeroblob(\(noteLimit + 1)) AS TEXT)",
            fp6SQL: "NULL"
        ) >= 4)
    }

    @Test
    func privateProtoRawAndUpdatedPayloadsRespectFixedBudget() throws {
        let maximum = CloudProjectionResourcePolicy.bookAnnotationsBytes
        let row: NSDictionary = [
            "uuid": "uuid-probe",
            "deleted": false,
            "modified": 2.0,
            "note": NSNull(),
            "fp6": NSNull(),
        ]

        let acceptedCloud = FakeAnnotationCloudObject(bookAnnotations: Data(count: maximum))
        let accepted = testUpdateExistingAnnotationCloudObjectWithBookClass(
            Unmanaged.passUnretained(acceptedCloud).toOpaque(),
            Unmanaged.passUnretained(row).toOpaque(),
            FakeSmallUpdatedProtoBook.self
        )
        #expect(accepted != 0)
        #expect(acceptedCloud.setCount == 1)

        let oversizedRawCloud = FakeAnnotationCloudObject(bookAnnotations: Data(count: maximum + 1))
        let oversizedRaw = testUpdateExistingAnnotationCloudObjectWithBookClass(
            Unmanaged.passUnretained(oversizedRawCloud).toOpaque(),
            Unmanaged.passUnretained(row).toOpaque(),
            NSObject.self
        )
        #expect(oversizedRaw == 0)
        #expect(oversizedRawCloud.setCount == 0)

        let oversizedUpdatedCloud = FakeAnnotationCloudObject(bookAnnotations: Data([0]))
        let oversizedUpdated = testUpdateExistingAnnotationCloudObjectWithBookClass(
            Unmanaged.passUnretained(oversizedUpdatedCloud).toOpaque(),
            Unmanaged.passUnretained(row).toOpaque(),
            FakeOversizedUpdatedProtoBook.self
        )
        #expect(oversizedUpdated == 0)
        #expect(oversizedUpdatedCloud.setCount == 0)
    }

    @Test
    func bridgeClearRemovesExistingSerializedNote() throws {
        let framework = dlopen(
            "/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore",
            RTLD_NOW
        )
        #expect(framework != nil)
        defer { if let framework { dlclose(framework) } }

        let annotationClass = try #require(NSClassFromString("BCProtoAnnotation") as? NSObject.Type)
        let bookClass = try #require(NSClassFromString("BCAnnotationsProtoBook") as? NSObject.Type)
        let cloudClass = try #require(NSClassFromString("BCMutableAssetAnnotations") as? NSObject.Type)

        let annotation = annotationClass.init()
        _ = annotation.perform(NSSelectorFromString("setUuid:"), with: "uuid-probe")
        _ = annotation.perform(NSSelectorFromString("setCreatorIdentifier:"), with: "creator-probe")
        annotation.setValue(1.0, forKey: "creationDate")
        annotation.setValue(1.0, forKey: "modificationDate")
        _ = annotation.perform(NSSelectorFromString("setNote:"), with: "old note")

        let book = bookClass.init()
        _ = book.perform(NSSelectorFromString("setAssetID:"), with: "asset-probe")
        _ = book.perform(NSSelectorFromString("setAppVersion:"), with: "1")
        _ = book.perform(NSSelectorFromString("setAssetVersion:"), with: "1")
        _ = book.perform(NSSelectorFromString("addAnnotation:"), with: annotation)
        let original = try #require(book.value(forKey: "data") as? Data)

        let cloudShell = cloudClass.init()
        let cloudObject = try #require(
            cloudShell.perform(NSSelectorFromString("initWithAssetID:"), with: "asset-probe")?
                .takeUnretainedValue() as? NSObject
        )
        cloudObject.setValue(original, forKey: "bookAnnotations")
        let row: NSDictionary = [
            "uuid": "uuid-probe",
            "deleted": false,
            "modified": 2.0,
            "note": NSNull(),
            "fp6": NSNull(),
        ]

        let success = updateExistingAnnotationCloudObject(
            Unmanaged.passUnretained(cloudObject).toOpaque(),
            Unmanaged.passUnretained(row).toOpaque()
        )
        #expect(success != 0)

        let updated = try #require(cloudObject.value(forKey: "bookAnnotations") as? Data)
        let decodedShell = bookClass.init()
        let decoded = try #require(
            decodedShell.perform(NSSelectorFromString("initWithData:"), with: updated)?
                .takeUnretainedValue() as? NSObject
        )
        let decodedAnnotations = try #require(decoded.value(forKey: "annotations") as? [NSObject])
        let decodedAnnotation = try #require(decodedAnnotations.first)
        #expect((decodedAnnotation.value(forKey: "hasNote") as? NSNumber)?.boolValue == false)
        #expect(decodedAnnotation.value(forKey: "note") == nil)
        #expect((decodedAnnotation.value(forKey: "hasDeleted") as? NSNumber)?.boolValue == true)
        #expect((decodedAnnotation.value(forKey: "deleted") as? NSNumber)?.boolValue == false)
    }

    @Test
    func nonCanonicalAnnotationsDatabaseDisablesLiveProjection() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("fixture.sqlite")
        try Data().write(to: outside)
        #expect(AnnotationCloudProjector.live(annotationsDatabase: outside, homeDirectory: root) == nil)
    }

    @Test
    func identityRequiresUniqueNonEmptyAssetAndUUID() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("annotations.sqlite")
        try execute(database, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT); INSERT INTO ZAEANNOTATION VALUES(1,'ASSET','UUID'),(1,'OTHER','OTHER')")
        #expect(throws: AnnotationCloudProjectionError.identityUnavailable) {
            _ = try AnnotationCloudProjector.identity(annotationsDatabase: database, localPK: 1)
        }
    }

    @Test
    func bridgeRejectsWrongAnnotationStoreLayoutBeforePrivateFrameworkAccess() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let database = storeDirectory.appendingPathComponent("BCAssetData")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try Data().write(to: database)
        try Data().write(to: annotations)
        let status = storeDirectory.path.withCString { rootPath in
            database.path.withCString { databasePath in
                annotations.path.withCString { annotationsPath in
                    withCloudBridgeUTF8Bytes("\0ASSET") { assetID, assetIDLength in
                        withCloudBridgeUTF8Bytes("UUID") { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                databasePath,
                                annotationsPath,
                                assetID,
                                assetIDLength,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
        #expect(status == 2)

        let invalidBytes: [UInt8] = [0xFF]
        let invalidStatus = storeDirectory.path.withCString { rootPath in
            database.path.withCString { databasePath in
                annotations.path.withCString { annotationsPath in
                    invalidBytes.withUnsafeBufferPointer { invalid in
                        withCloudBridgeUTF8Bytes("UUID") { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                databasePath,
                                annotationsPath,
                                invalid.baseAddress!,
                                invalid.count,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
        #expect(invalidStatus == 1)
    }

    private func annotationBridgeStatus(deleted: Bool, noteSQL: String, fp6SQL: String) throws -> Int32 {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let cloudDatabase = storeDirectory.appendingPathComponent("BCAssetData")
        try Data().write(to: cloudDatabase)
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try execute(annotations, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONNOTE TEXT,
              ZFUTUREPROOFING6 TEXT,
              ZANNOTATIONTYPE INTEGER
            );
            INSERT INTO ZAEANNOTATION VALUES(
              7,'ASSET','UUID',\(deleted ? 1 : 0),1,\(noteSQL),\(fp6SQL),1
            );
            """)
        return root.path.withCString { rootPath in
            cloudDatabase.path.withCString { cloudPath in
                annotations.path.withCString { annotationsPath in
                    withCloudBridgeUTF8Bytes("ASSET") { assetID, assetIDLength in
                        withCloudBridgeUTF8Bytes("UUID") { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                cloudPath,
                                annotationsPath,
                                assetID,
                                assetIDLength,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
    }

    private func insertIdentity(_ database: URL, assetID: String, uuid: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ZAEANNOTATION(Z_PK,ZANNOTATIONASSETID,ZANNOTATIONUUID) VALUES(7,?,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle) }
        defer { sqlite3_finalize(statement) }
        try bindExact(assetID, to: statement, index: 1, handle: handle)
        try bindExact(uuid, to: statement, index: 2, handle: handle)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func insertBridgeTarget(_ database: URL, assetID: String, uuid: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let sql = "INSERT INTO ZAEANNOTATION VALUES(7,?,?,0,1,NULL,NULL,1)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle) }
        defer { sqlite3_finalize(statement) }
        try bindExact(assetID, to: statement, index: 1, handle: handle)
        try bindExact(uuid, to: statement, index: 2, handle: handle)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func bindExact(_ value: String, to statement: OpaquePointer, index: Int32, handle: OpaquePointer) throws {
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes { raw in
            sqlite3_bind_text64(
                statement,
                index,
                raw.baseAddress,
                sqlite3_uint64(raw.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self),
                UInt8(SQLITE_UTF8)
            )
        }
        guard result == SQLITE_OK else { throw SQLiteError.current(operation: .bind, code: result, handle: handle) }
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func execute(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }
}

private final class FakeAnnotationCloudObject: NSObject {
    private var payload: Data
    private(set) var setCount = 0

    init(bookAnnotations: Data) {
        payload = bookAnnotations
    }

    @objc(bookAnnotations)
    func bookAnnotations() -> Data { payload }

    @objc(setBookAnnotations:)
    func setBookAnnotations(_ value: Data) {
        payload = value
        setCount += 1
    }
}

private final class FakeProtoAnnotation: NSObject {
    @objc(uuid)
    func uuid() -> String { "uuid-probe" }

    @objc(setNote:)
    func setNote(_ value: String?) {}

    @objc(setDeleted:)
    func setDeleted(_ value: Bool) {}

    @objc(setHasDeleted:)
    func setHasDeleted(_ value: Bool) {}

    @objc(setModificationDate:)
    func setModificationDate(_ value: Double) {}

    @objc(setUserModificationDate:)
    func setUserModificationDate(_ value: Double) {}

    @objc(setHasUserModificationDate:)
    func setHasUserModificationDate(_ value: Bool) {}
}

private class FakeProtoBookBase: NSObject {
    private let annotation = FakeProtoAnnotation()

    @objc(initWithData:)
    required init(data: Data) {
        super.init()
    }

    @objc(annotations)
    func annotations() -> [Any] { [annotation] }
}

private final class FakeSmallUpdatedProtoBook: FakeProtoBookBase {
    @objc(data)
    func data() -> Data { Data([1]) }
}

private final class FakeOversizedUpdatedProtoBook: FakeProtoBookBase {
    @objc(data)
    func data() -> Data { Data(count: CloudProjectionResourcePolicy.bookAnnotationsBytes + 1) }
}
