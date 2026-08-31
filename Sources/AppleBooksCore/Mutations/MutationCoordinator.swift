import Foundation
import SQLite3

public struct MutationCommittedVerificationError: Error, Equatable, Sendable {
    public let committed = true
    public let backupFilename: String
    public let localPK: Int64?
    public let code: String

    init(backupFilename: String, localPK: Int64?, code: String) {
        self.backupFilename = backupFilename
        self.localPK = localPK
        self.code = code
    }
}

enum MutationCoordinatorError: Error, Equatable {
    case booksRunning
    case databaseOpenFailed(Int32)
    case busyTimeoutFailed(Int32)
    case beginFailed(Int32)
    case commitFailed(Int32)
}

struct MutationCoordinator {
    let database: URL
    let backupRoot: URL
    let keep: Int
    let booksIsRunning: () -> Bool

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksIsRunning: @escaping () -> Bool = isBooksAppRunning
    ) {
        self.database = database
        self.backupRoot = backupRoot
        self.keep = keep
        self.booksIsRunning = booksIsRunning
    }

    func perform<T>(
        preflight: (SQLiteConnection) throws -> Void,
        revalidate: (OpaquePointer) throws -> Void,
        mutation: (OpaquePointer) throws -> T,
        invariant: (OpaquePointer, T) throws -> Void = { _, _ in },
        committedLocalPK: (T) -> Int64? = { _ in nil },
        readBack: (SQLiteConnection, T) throws -> Void
    ) throws -> T {
        try performAndReadBack(
            preflight: preflight,
            revalidate: revalidate,
            mutation: mutation,
            invariant: invariant,
            committedLocalPK: committedLocalPK,
            readBack: { connection, result in
                try readBack(connection, result)
                return result
            }
        )
    }

    func performAndReadBack<T, R>(
        preflight: (SQLiteConnection) throws -> Void,
        revalidate: (OpaquePointer) throws -> Void,
        mutation: (OpaquePointer) throws -> T,
        invariant: (OpaquePointer, T) throws -> Void = { _, _ in },
        committedLocalPK: (T) -> Int64? = { _ in nil },
        readBack: (SQLiteConnection, T) throws -> R
    ) throws -> R {
        let preflightConnection = try SQLiteConnection.readOnly(path: database.path)
        do {
            try preflight(preflightConnection)
            try preflightConnection.close()
        } catch {
            try? preflightConnection.close()
            throw error
        }

        guard booksIsRunning() == false else {
            throw MutationCoordinatorError.booksRunning
        }
        let backup = try SQLiteBackup.create(source: database, backupRoot: backupRoot, keep: keep)

        var handle: OpaquePointer?
        let open = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard open == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MutationCoordinatorError.databaseOpenFailed(open)
        }
        var transactionOpen = false
        var closeNeeded = true
        defer {
            if transactionOpen {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            }
            if closeNeeded {
                sqlite3_close_v2(handle)
            }
        }

        let busy = sqlite3_busy_timeout(handle, 5_000)
        guard busy == SQLITE_OK else { throw MutationCoordinatorError.busyTimeoutFailed(busy) }
        let begin = sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil)
        guard begin == SQLITE_OK else { throw MutationCoordinatorError.beginFailed(begin) }
        transactionOpen = true

        let result: T
        do {
            try revalidate(handle)
            result = try mutation(handle)
            try invariant(handle, result)
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            transactionOpen = false
            throw error
        }

        let commit = sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        guard commit == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            transactionOpen = false
            throw MutationCoordinatorError.commitFailed(commit)
        }
        transactionOpen = false

        let localPK = committedLocalPK(result)
        let close = sqlite3_close(handle)
        guard close == SQLITE_OK else {
            throw MutationCommittedVerificationError(
                backupFilename: backup.lastPathComponent,
                localPK: localPK,
                code: "close_failed"
            )
        }
        closeNeeded = false

        let readBackConnection: SQLiteConnection
        do {
            readBackConnection = try SQLiteConnection.readOnly(path: database.path)
        } catch {
            throw MutationCommittedVerificationError(
                backupFilename: backup.lastPathComponent,
                localPK: localPK,
                code: "read_back_open_failed"
            )
        }
        do {
            let finalResult = try readBack(readBackConnection, result)
            try readBackConnection.close()
            return finalResult
        } catch {
            try? readBackConnection.close()
            throw MutationCommittedVerificationError(
                backupFilename: backup.lastPathComponent,
                localPK: localPK,
                code: "read_back_failed"
            )
        }
    }
}
