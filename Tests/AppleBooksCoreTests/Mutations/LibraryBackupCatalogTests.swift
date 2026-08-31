import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("LibraryBackupCatalogTests")
struct LibraryBackupCatalogTests {
    @Test
    func missingRootIsEmptyAndInvalidRootFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("library.sqlite")
        #expect(try SQLiteBackup.list(source: source, backupRoot: root).isEmpty)

        let fileRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not-a-directory".utf8).write(to: fileRoot)
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        #expect(throws: SQLiteBackupError.filesystemFailure) {
            _ = try SQLiteBackup.list(source: source, backupRoot: fileRoot)
        }
    }

    @Test
    func catalogListsOnlyOwnedRegularCompletedBackupsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("library.sqlite")

        let old = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newerLowUUID = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newerHighUUID = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            uuid: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        )
        try Data(repeating: 1, count: 3).write(to: root.appendingPathComponent(old.filename))
        try Data(repeating: 2, count: 5).write(to: root.appendingPathComponent(newerLowUUID.filename))
        try Data(repeating: 3, count: 7).write(to: root.appendingPathComponent(newerHighUUID.filename))

        let otherStore = BackupMetadata.fresh(sourceStem: "annotations")
        try Data(repeating: 4, count: 9).write(to: root.appendingPathComponent(otherStore.filename))
        try Data("partial".utf8).write(to: root.appendingPathComponent(newerLowUUID.filename + ".part"))
        try Data("malformed".utf8).write(to: root.appendingPathComponent("library__invalid.sqlite"))

        let directoryMetadata = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_900_000_000),
            uuid: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directoryMetadata.filename),
            withIntermediateDirectories: false
        )
        let symlinkMetadata = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_950_000_000),
            uuid: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(symlinkMetadata.filename),
            withDestinationURL: root.appendingPathComponent(old.filename)
        )

        let result = try SQLiteBackup.list(source: source, backupRoot: root)

        #expect(result.map(\.handle) == [newerHighUUID.filename, newerLowUUID.filename, old.filename])
        #expect(result.map(\.sizeBytes) == [7, 5, 3])
        #expect(result.allSatisfy { $0.handle.contains("/") == false })
        #expect(result[0].createdAt == BackupMetadata.parse(filename: newerHighUUID.filename, sourceStem: "library")?.timestamp)
    }

    @Test
    func facadeCatalogIsLibraryOnlyAndNeverReturnsAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try execute(library, "CREATE TABLE placeholder(value INTEGER)")
        try execute(annotations, "CREATE TABLE placeholder(value INTEGER)")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let libraryMetadata = BackupMetadata.fresh(sourceStem: "library")
        let annotationMetadata = BackupMetadata.fresh(sourceStem: "annotations")
        try Data(repeating: 1, count: 4).write(to: backupRoot.appendingPathComponent(libraryMetadata.filename))
        try Data(repeating: 2, count: 8).write(to: backupRoot.appendingPathComponent(annotationMetadata.filename))
        let closed = closedController()
        let books = try AppleBooks(
            libraryDB: library,
            annotationsDB: annotations,
            configurationFile: config,
            collectionWriter: CollectionWriter(database: library, backupRoot: backupRoot, booksApp: closed),
            annotationWriter: AnnotationWriter(database: annotations, backupRoot: backupRoot, booksApp: closed),
            libraryBackupRoot: backupRoot
        )

        let result = try books.listLibraryBackups()

        #expect(result.count == 1)
        #expect(result[0].handle == libraryMetadata.filename)
        #expect(result[0].sizeBytes == 4)
        #expect(result[0].handle.hasPrefix(root.path) == false)
    }

    private func closedController() -> BooksAppController {
        BooksAppController(
            isRunning: { false },
            terminate: { true },
            launch: {},
            sleep: { _ in }
        )
    }

    private func execute(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }
}
