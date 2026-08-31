import Foundation
import SQLite3

struct MutationCoordinator {
    let database: URL
    let backupRoot: URL
    let keep: Int
    let booksApp: BooksAppController
    private let backupAction: () throws -> URL

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksApp: BooksAppController = .live,
        backupAction: (() throws -> URL)? = nil
    ) {
        self.database = database
        self.backupRoot = backupRoot
        self.keep = keep
        self.booksApp = booksApp
        self.backupAction = backupAction ?? {
            try SQLiteBackup.create(source: database, backupRoot: backupRoot, keep: keep)
        }
    }

    func perform<T>(
        preflight: (SQLiteConnection) throws -> Void,
        revalidate: (OpaquePointer) throws -> Void,
        mutation: (OpaquePointer) throws -> T,
        invariant: (OpaquePointer, T) throws -> Void = { _, _ in },
        domainData: (T) -> MutationDomainData,
        readBack: (SQLiteConnection, T) throws -> Void
    ) throws -> MutationResult {
        let preflightConnection = try SQLiteConnection.readOnly(path: database.path)
        do {
            try preflight(preflightConnection)
            try preflightConnection.close()
        } catch {
            try? preflightConnection.close()
            throw error
        }

        let wasRunning = booksApp.isRunning()
        if wasRunning {
            do {
                try booksApp.terminateAndWait()
            } catch {
                throw MutationFailure(
                    backupHandle: nil,
                    code: .quitFailed,
                    warnings: [],
                    underlying: error
                )
            }
        }

        let backup: URL
        do {
            backup = try backupAction()
        } catch {
            throw failure(
                error,
                code: .backupFailed,
                backupHandle: nil,
                restoreBooks: wasRunning
            )
        }
        let backupHandle = backup.lastPathComponent

        var handle: OpaquePointer?
        let open = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard open == SQLITE_OK, let handle else {
            let openError = SQLiteError.current(operation: .open, code: open, handle: handle)
            if let handle { sqlite3_close_v2(handle) }
            throw failure(
                openError,
                code: .databaseOpenFailed,
                backupHandle: backupHandle,
                restoreBooks: wasRunning
            )
        }

        var transactionOpen = false
        var writableOpen = true
        defer {
            if transactionOpen {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            }
            if writableOpen {
                sqlite3_close_v2(handle)
            }
        }

        let busy = sqlite3_busy_timeout(handle, 5_000)
        guard busy == SQLITE_OK else {
            let busyError = SQLiteError.current(operation: .step, code: busy, handle: handle)
            writableOpen = false
            sqlite3_close_v2(handle)
            throw failure(
                busyError,
                code: .busyTimeoutFailed,
                backupHandle: backupHandle,
                restoreBooks: wasRunning
            )
        }

        let begin = sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil)
        guard begin == SQLITE_OK else {
            let beginError = SQLiteError.current(operation: .step, code: begin, handle: handle)
            writableOpen = false
            sqlite3_close_v2(handle)
            throw failure(
                beginError,
                code: .beginFailed,
                backupHandle: backupHandle,
                restoreBooks: wasRunning
            )
        }
        transactionOpen = true

        do {
            try revalidate(handle)
        } catch {
            rollbackAndClose(handle, transactionOpen: &transactionOpen, writableOpen: &writableOpen)
            throw failure(error, code: .revalidateFailed, backupHandle: backupHandle, restoreBooks: wasRunning)
        }

        let payload: T
        do {
            payload = try mutation(handle)
        } catch {
            rollbackAndClose(handle, transactionOpen: &transactionOpen, writableOpen: &writableOpen)
            throw failure(error, code: .mutationFailed, backupHandle: backupHandle, restoreBooks: wasRunning)
        }

        do {
            try invariant(handle, payload)
        } catch {
            rollbackAndClose(handle, transactionOpen: &transactionOpen, writableOpen: &writableOpen)
            throw failure(error, code: .invariantFailed, backupHandle: backupHandle, restoreBooks: wasRunning)
        }

        let commit = sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        guard commit == SQLITE_OK else {
            let commitError = SQLiteError.current(operation: .step, code: commit, handle: handle)
            rollbackAndClose(handle, transactionOpen: &transactionOpen, writableOpen: &writableOpen)
            throw failure(
                commitError,
                code: .commitFailed,
                backupHandle: backupHandle,
                restoreBooks: wasRunning
            )
        }
        transactionOpen = false

        var warnings: [MutationWarning] = []
        let close = sqlite3_close(handle)
        if close == SQLITE_OK {
            writableOpen = false
        } else {
            warnings.append(.writableCloseFailed)
            _ = sqlite3_close_v2(handle)
            writableOpen = false
        }

        do {
            let readBackConnection = try SQLiteConnection.readOnly(path: database.path)
            do {
                try readBack(readBackConnection, payload)
                try readBackConnection.close()
            } catch {
                try? readBackConnection.close()
                warnings.append(.readBackFailed)
            }
        } catch {
            warnings.append(.readBackFailed)
        }

        if wasRunning {
            do {
                try booksApp.launch()
            } catch {
                warnings.append(.relaunchFailed)
            }
        }

        let domain = domainData(payload)
        return MutationResult(
            backupHandle: backupHandle,
            localPK: domain.localPK,
            stableID: domain.stableID,
            changed: domain.changed,
            warnings: warnings
        )
    }

    private func failure(
        _ underlying: any Error,
        code: MutationFailureCode,
        backupHandle: String?,
        restoreBooks: Bool
    ) -> MutationFailure {
        var warnings: [MutationWarning] = []
        if restoreBooks {
            do {
                try booksApp.launch()
            } catch {
                warnings.append(.relaunchFailed)
            }
        }
        return MutationFailure(
            backupHandle: backupHandle,
            code: code,
            warnings: warnings,
            underlying: underlying
        )
    }

    private func rollbackAndClose(
        _ handle: OpaquePointer,
        transactionOpen: inout Bool,
        writableOpen: inout Bool
    ) {
        if transactionOpen {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            transactionOpen = false
        }
        if writableOpen {
            sqlite3_close_v2(handle)
            writableOpen = false
        }
    }
}
