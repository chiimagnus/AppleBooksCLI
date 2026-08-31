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
            invariant: { handle, _ in
                stages.append("invariant")
                #expect(self.rawValue(handle) == "after")
            },
            committedLocalPK: { $0 },
            readBack: { connection, localPK in
                stages.append("readBack")
                #expect(localPK == 42)
                #expect(sqlite3_db_readonly(connection.handle, "main") == 1)
                let actual = try self.value(connection)
                #expect(actual == "after")
            }
        )

        #expect(result == 42)
        #expect(stages == ["preflight", "revalidate", "mutation", "invariant", "readBack"])
        #expect(try readValue(at: fixture.database) == "after")
    }

    @Test
    func preflightAndBooksRunningFailBeforeBackupOrMutation() throws {
        let preflightFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: preflightFixture.root) }
        #expect(throws: TestFailure.preflight) {
            _ = try preflightFixture.coordinator.perform(
                preflight: { _ in throw TestFailure.preflight },
                revalidate: { _ in },
                mutation: { _ in () },
                readBack: { _, _ in }
            )
        }
        #expect(FileManager.default.fileExists(atPath: preflightFixture.backupRoot.path) == false)
        #expect(try readValue(at: preflightFixture.database) == "before")

        let runningFixture = try fixture(booksRunning: true)
        defer { try? FileManager.default.removeItem(at: runningFixture.root) }
        #expect(throws: MutationCoordinatorError.booksRunning) {
            _ = try runningFixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { _ in () },
                readBack: { _, _ in }
            )
        }
        #expect(FileManager.default.fileExists(atPath: runningFixture.backupRoot.path) == false)
        #expect(try readValue(at: runningFixture.database) == "before")
    }

    @Test
    func callbackFailureRollsBackAndCommittedReadBackFailureIsTyped() throws {
        let rollbackFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: rollbackFixture.root) }
        #expect(throws: TestFailure.mutation) {
            _ = try rollbackFixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { handle in
                    try self.setValue(handle, "partial")
                    throw TestFailure.mutation
                },
                readBack: { _, _ in }
            ) as Void
        }
        #expect(try readValue(at: rollbackFixture.database) == "before")
        #expect(try completedBackups(in: rollbackFixture.backupRoot).count == 1)

        let committedFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: committedFixture.root) }
        do {
            _ = try committedFixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { handle in
                    try self.setValue(handle, "committed")
                    return Int64(77)
                },
                committedLocalPK: { $0 },
                readBack: { _, _ in throw TestFailure.readBack }
            )
            Issue.record("expected committed verification error")
        } catch let error as MutationCommittedVerificationError {
            #expect(error.committed)
            #expect(error.localPK == 77)
            #expect(error.code == "read_back_failed")
            #expect(BackupMetadata.parse(filename: error.backupFilename, sourceStem: "library") != nil)
        }
        #expect(try readValue(at: committedFixture.database) == "committed")
    }

    @Test
    func committedCloseFailureCannotMasqueradeAsUncommittedFailure() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var leakedStatement: OpaquePointer?

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { handle in
                    try self.setValue(handle, "committed")
                    guard sqlite3_prepare_v2(handle, "SELECT value FROM sample", -1, &leakedStatement, nil) == SQLITE_OK else {
                        throw TestFailure.mutation
                    }
                    return Int64(88)
                },
                committedLocalPK: { $0 },
                readBack: { _, _ in Issue.record("read-back must not run before writable close") }
            )
            Issue.record("expected committed close error")
        } catch let error as MutationCommittedVerificationError {
            #expect(error.committed)
            #expect(error.localPK == 88)
            #expect(error.code == "close_failed")
        }
        if let leakedStatement { sqlite3_finalize(leakedStatement) }
        #expect(try readValue(at: fixture.database) == "committed")
    }

    private func fixture(booksRunning: Bool = false) throws -> Fixture {
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
                booksIsRunning: { booksRunning }
            )
        )
    }

    private func value(_ connection: SQLiteConnection) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func readValue(at url: URL) throws -> String? {
        try value(SQLiteConnection.readOnly(path: url.path))
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
