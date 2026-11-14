import AppleBooksCloudBridge
import CoreData
import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("NativeAnnotationCreateBridgeTests", .serialized)
struct NativeAnnotationCreateBridgeTests {
    @Test
    func createsNewUUIDUnderExistingNativeParentInIsolatedCoreDataStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloudDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
        let cloudDB = cloudDirectory.appendingPathComponent("BCAssetData")
        let localDB = root.appendingPathComponent("annotations.sqlite")

        let framework = dlopen(
            "/System/Library/PrivateFrameworks/BookDataStore.framework/BookDataStore", RTLD_NOW
        )
        let validFramework = try #require(framework)
        defer { dlclose(validFramework) }
        let owner: AnyClass = try #require(NSClassFromString("BCCloudAssetAnnotationManager"))
        let bundle = Bundle(for: owner)
        let modelURL = try #require(bundle.url(forResource: "BCAssetData", withExtension: "momd"))
        let model = try #require(NSManagedObjectModel(contentsOf: modelURL))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: cloudDB,
            options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        )
        defer { try? coordinator.remove(store) }
        let bookClass = try #require(NSClassFromString("BCAnnotationsProtoBook") as? NSObject.Type)
        let initialBook = bookClass.init()
        let seedAssetID = "synthetic-asset"
        _ = initialBook.perform(NSSelectorFromString("setAssetID:"), with: seedAssetID)
        _ = initialBook.perform(NSSelectorFromString("setAppVersion:"), with: "1")
        let initialData = try #require(initialBook.value(forKey: "data") as? Data)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let parent = NSEntityDescription.insertNewObject(
                forEntityName: "BCAssetAnnotations", into: context
            )
            parent.setValue(seedAssetID, forKey: "assetID")
            parent.setValue(initialData, forKey: "bookAnnotations")
            try context.save()
        }
        try execute(localDB, """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT,
                ZANNOTATIONTYPE INTEGER,ZANNOTATIONDELETED INTEGER,ZANNOTATIONSTYLE INTEGER,
                ZANNOTATIONISUNDERLINE INTEGER,ZANNOTATIONCREATIONDATE REAL,
                ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONSELECTEDTEXT TEXT,
                ZANNOTATIONREPRESENTATIVETEXT TEXT,ZANNOTATIONLOCATION TEXT,
                ZANNOTATIONNOTE TEXT,ZANNOTATIONCREATORIDENTIFIER TEXT
            );
            INSERT INTO ZAEANNOTATION VALUES(1,'synthetic-asset','synthetic-uuid-1',2,0,1,0,100.0,101.0,
                'first','first synthetic chapter','synthetic:cfi-one',
                'Synthetic note','com~apple~iBooks');
            INSERT INTO ZAEANNOTATION VALUES(2,'synthetic-asset','synthetic-uuid-2',2,0,5,1,102.0,103.0,
                'second','second synthetic chapter','synthetic:cfi-two',
                NULL,'com~apple~iBooks');
            """)
        func project(_ uuid: String, assetID: String = "synthetic-asset") -> Int32 {
            root.path.withCString { r in
                cloudDB.path.withCString { c in
                    localDB.path.withCString { l in
                        withCloudBridgeUTF8Bytes(assetID) { asset, al in
                            withCloudBridgeUTF8Bytes(uuid) { id, il in
                                ABCreateAnnotationState(r, c, l, asset, al, id, il)
                            }
                        }
                    }
                }
            }
        }
        #expect(project("synthetic-uuid-1") == 0)
        try verifyNativeCloud(cloudDB, expectedCount: 1, values: ["synthetic-uuid-1": (1, false, "Synthetic note")])
        #expect(project("synthetic-uuid-1") == 0, "Idempotent re-projection must not create a duplicate")
        try verifyNativeCloud(cloudDB, expectedCount: 1, values: ["synthetic-uuid-1": (1, false, "Synthetic note")])
        #expect(project("synthetic-uuid-2") == 0)
        try verifyNativeCloud(cloudDB, expectedCount: 2, values: [
            "synthetic-uuid-1": (1, false, "Synthetic note"),
            "synthetic-uuid-2": (5, true, nil),
        ])
        #expect(project("synthetic-uuid-2") == 0)
        try verifyNativeCloud(cloudDB, expectedCount: 2, values: [
            "synthetic-uuid-1": (1, false, "Synthetic note"),
            "synthetic-uuid-2": (5, true, nil),
        ])
        try execute(localDB, """
            UPDATE ZAEANNOTATION SET ZANNOTATIONSELECTEDTEXT='mismatched'
            WHERE ZANNOTATIONUUID='synthetic-uuid-1';
            """)
        #expect(project("synthetic-uuid-1") == 12, "Different local content must not overwrite an existing cloud UUID")
        try verifyNativeCloud(cloudDB, expectedCount: 2, values: [
            "synthetic-uuid-1": (1, false, "Synthetic note"),
            "synthetic-uuid-2": (5, true, nil),
        ])
        try execute(localDB, """
            INSERT INTO ZAEANNOTATION VALUES(3,'synthetic-missing-parent','synthetic-uuid-3',2,0,1,0,104.0,105.0,
                'third','third synthetic chapter','synthetic:cfi-three',NULL,'com~apple~iBooks');
            """)
        #expect(project("synthetic-uuid-3", assetID: "synthetic-missing-parent") == 18)
        let read = try SQLiteConnection.readOnly(path: cloudDB.path)
        defer { try? read.close() }
        let missing = try read.prepare("SELECT Z_PK FROM ZBCASSETANNOTATIONS WHERE ZASSETID='synthetic-missing-parent'")
        #expect(try !missing.step(), "A missing parent must not be created or crash the process")
    }

    private func verifyNativeCloud(
        _ database: URL, expectedCount: Int,
        values: [String: (Int, Bool, String?)]
    ) throws {
        let conn = try SQLiteConnection.readOnly(path: database.path)
        defer { try? conn.close() }
        let statement = try conn.prepare("""
            SELECT ZBOOKANNOTATIONS FROM ZBCASSETANNOTATIONS
            WHERE ZASSETID='synthetic-asset' ORDER BY Z_PK LIMIT 2
            """)
        guard try statement.step() else { throw VerificationError.missing }
        let handle = try #require(statement.handle)
        let pointer = try #require(sqlite3_column_blob(handle, 0))
        let count = sqlite3_column_bytes(handle, 0)
        let blob = Data(bytes: pointer, count: Int(count))
        #expect(try !statement.step())
        let cls = try #require(NSClassFromString("BCAnnotationsProtoBook") as? NSObject.Type)
        let decoded = try #require(
            cls.init().perform(NSSelectorFromString("initWithData:"), with: blob)?
                .takeUnretainedValue() as? NSObject
        )
        let records = try #require(decoded.value(forKey: "annotations") as? [NSObject])
        #expect(records.count == expectedCount)
        for item in records {
            let uuid = try #require(item.value(forKey: "uuid") as? String)
            let expected = try #require(values[uuid])
            #expect((item.value(forKey: "style") as? NSNumber)?.intValue == expected.0)
            #expect((item.value(forKey: "isUnderline") as? NSNumber)?.boolValue == expected.1)
            #expect(item.value(forKey: "note") as? String == expected.2)
        }
    }

    private func execute(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else {
            throw VerificationError.missing
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VerificationError.invalidSQL
        }
    }

    private enum VerificationError: Error { case missing, invalidSQL }
}
