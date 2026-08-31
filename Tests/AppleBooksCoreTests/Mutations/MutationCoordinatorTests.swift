import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("MutationCoordinatorTests")
struct MutationCoordinatorTests {
    @Test
    func runsSingleWriteRailWithBackupTransactionAndReadBack() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var stages: [String] = []

        let result = try fixture.coordinator.perform(
            preflight: { connection in
                stages.append("preflight")
                #expect(sqlite3_db_readonly(connection.handle, "main") == 1)
                let actual = try self.value(connection)
                #expect(actual == "before")
            },
            revalidate: { handle in
                stages.append("revalidate")
                #expect(sqlite3_get_autocommit(handle) == 0)
                #expect(self.busyTimeout(handle) == 5_000)
                let backupCount = try self.completedBackups(in: fixture.backupRoot).count
                #expect(backupCount == 1)
            },
            mutation: { handle in
                stages.append("mutation")
                try self.setValue(handle, "after")
                return Int64(42)
            },
            invariant: { handle, localPK in
                stages.append("invariant")
                #expect(localPK == 42)
                #expect(self.rawValue(handle) == "after")
            },
            domainData: { MutationDomainData(localPK: $0, stableID: "sample", changed: true) },
            readBack: { connection, localPK in
                stages.append("readBack")
                #expect(localPK == 42)
                #expect(sqlite3_db_readonly(connection.handle, "main") == 1)
                let actual = try self.value(connection)
                #expect(actual == "after")
            }
        )

        #expect(result.committed)
        #expect(result.localPK == 42)
        #expect(result.stableID == "sample")
        #expect(result.changed)
        #expect(result.warnings.isEmpty)
        #expect(BackupMetadata.parse(filename: result.backupHandle, sourceStem: "library") != nil)
        #expect(stages == ["preflight", "revalidate", "mutation", "invariant", "readBack"])
        #expect(try readValue(at: fixture.database) == "after")
    }

    @Test
    func preflightFailureHappensBeforeBackup() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: TestFailure.preflight) {
            _ = try fixture.coordinator.perform(
                preflight: { _ in throw TestFailure.preflight },
                revalidate: { _ in },
                mutation: { _ in () },
                domainData: { _ in MutationDomainData(changed: false) },
                readBack: { _, _ in }
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
        #expect(try readValue(at: fixture.database) == "before")
    }

    @Test
    func mutationFailureRollsBackAndKeepsBackupHandle() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { handle in
                    try self.setValue(handle, "partial")
                    throw TestFailure.mutation
                },
                domainData: { (_: Void) in MutationDomainData(changed: true) },
                readBack: { _, _ in }
            )
            Issue.record("expected mutation failure")
        } catch let failure as MutationFailure {
            #expect(failure.committed == false)
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle != nil)
            #expect(failure.warnings.isEmpty)
            #expect(failure.underlying as? TestFailure == .mutation)
        }

        #expect(try readValue(at: fixture.database) == "before")
        #expect(try completedBackups(in: fixture.backupRoot).count == 1)
    }

    @Test
    func committedReadBackFailureReturnsSuccessWithWarning() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(77)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { _, _ in throw TestFailure.readBack }
        )

        #expect(result.committed)
        #expect(result.localPK == 77)
        #expect(result.warnings == [.readBackFailed])
        #expect(BackupMetadata.parse(filename: result.backupHandle, sourceStem: "library") != nil)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func committedCloseFailureIsWarningAndReadBackStillRuns() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var leakedStatement: OpaquePointer?
        var readBackRan = false

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                guard sqlite3_prepare_v2(handle, "SELECT value FROM sample", -1, &leakedStatement, nil) == SQLITE_OK else {
                    throw TestFailure.mutation
                }
                return Int64(88)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { connection, _ in
                readBackRan = true
                let actual = try self.value(connection)
                #expect(actual == "committed")
            }
        )

        #expect(result.committed)
        #expect(result.localPK == 88)
        #expect(result.warnings == [.writableCloseFailed])
        #expect(readBackRan)
        if let leakedStatement { sqlite3_finalize(leakedStatement) }
        #expect(try readValue(at: fixture.database) == "committed")
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('before')", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        let backupRoot = root.appendingPathComponent("backups")
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            coordinator: MutationCoordinator(
                database: database,
                backupRoot: backupRoot,
                booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {})
            )
        )
    }

    private func value(_ connection: SQLiteConnection) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func readValue(at url: URL) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: url.path)
        defer { try? connection.close() }
        return try value(connection)
    }

    private func setValue(_ handle: OpaquePointer, _ value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE sample SET value=?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        let bind = value.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func rawValue(_ handle: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM sample", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func busyTimeout(_ handle: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA busy_timeout", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func completedBackups(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { BackupMetadata.parse(filename: $0.lastPathComponent, sourceStem: "library") != nil }
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let coordinator: MutationCoordinator
    }

    private enum TestFailure: Error, Equatable {
        case preflight
        case mutation
        case readBack
    }
}
