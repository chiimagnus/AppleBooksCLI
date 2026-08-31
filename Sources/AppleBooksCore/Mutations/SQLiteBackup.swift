import Darwin
import Foundation
import SQLite3

public enum SQLiteBackupError: Error, Equatable, Sendable {
    case invalidRetention
    case sourceNotReadOnly
    case destinationOpenFailed
    case backupFailed(Int32)
    case integrityCheckFailed
    case filesystemFailure
    case retentionFailed
    case invalidRestoreSource
    case invalidRestoreDestination
    case restoreFailed(Int32)
}

public enum SQLiteBackup {
    public static let retentionCount = 10

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleBooksCLI/backups", isDirectory: true)
    }

    static func list(
        source: URL,
        backupRoot: URL = defaultRoot()
    ) throws -> [LibraryBackup] {
        var rootStat = stat()
        guard lstat(backupRoot.path, &rootStat) == 0 else {
            if errno == ENOENT { return [] }
            throw SQLiteBackupError.filesystemFailure
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw SQLiteBackupError.filesystemFailure
        }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: backupRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SQLiteBackupError.filesystemFailure
        }

        let sourceStem = source.deletingPathExtension().lastPathComponent
        var backups: [(LibraryBackup, BackupMetadata)] = []
        for entry in entries {
            guard let metadata = BackupMetadata.parse(
                filename: entry.lastPathComponent,
                sourceStem: sourceStem
            ) else {
                continue
            }
            var entryStat = stat()
            guard lstat(entry.path, &entryStat) == 0,
                  entryStat.st_mode & S_IFMT == S_IFREG,
                  entryStat.st_size >= 0 else {
                continue
            }
            backups.append((
                LibraryBackup(
                    handle: entry.lastPathComponent,
                    createdAt: metadata.timestamp,
                    sizeBytes: Int64(entryStat.st_size)
                ),
                metadata
            ))
        }

        backups.sort {
            if $0.1.timestamp != $1.1.timestamp { return $0.1.timestamp > $1.1.timestamp }
            return $0.1.uuid.uuidString > $1.1.uuid.uuidString
        }
        return backups.map(\.0)
    }

    @discardableResult
    public static func create(
        source: URL,
        backupRoot: URL = defaultRoot(),
        keep: Int = retentionCount
    ) throws -> URL {
        try create(source: source, backupRoot: backupRoot, keep: keep, preserving: [])
    }

    @discardableResult
    static func create(
        source: URL,
        backupRoot: URL,
        keep: Int,
        preserving: Set<String>
    ) throws -> URL {
        guard keep >= 1 else { throw SQLiteBackupError.invalidRetention }

        let sourceConnection = try SQLiteConnection.readOnly(path: source.path)
        guard let sourceHandle = sourceConnection.handle,
              sqlite3_db_readonly(sourceHandle, "main") == 1 else {
            throw SQLiteBackupError.sourceNotReadOnly
        }

        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        } catch {
            throw SQLiteBackupError.filesystemFailure
        }

        let sourceStem = source.deletingPathExtension().lastPathComponent
        let metadata = BackupMetadata.fresh(sourceStem: sourceStem)
        let final = backupRoot.appendingPathComponent(metadata.filename)
        let part = URL(fileURLWithPath: final.path + ".part")
        var published = false
        defer {
            if published == false {
                try? FileManager.default.removeItem(at: part)
            }
        }

        try copyOnline(sourceHandle: sourceHandle, to: part)
        try sourceConnection.close()
        try verifyIntegrity(of: part)
        try publish(part: part, final: final)
        published = true
        do {
            try applyRetention(
                in: backupRoot,
                sourceStem: sourceStem,
                keep: keep,
                preserving: preserving
            )
        } catch {
            throw SQLiteBackupError.retentionFailed
        }
        return final
    }

    static func openRestoreSource(
        handle: String,
        destination: URL,
        backupRoot: URL = defaultRoot()
    ) throws -> SQLiteConnection {
        let canonicalRoot = backupRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = backupRoot.appendingPathComponent(handle, isDirectory: false)
        let canonicalBackup = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let destinationStem = destination.deletingPathExtension().lastPathComponent

        var backupStat = stat()
        guard BackupMetadata.parse(filename: handle, sourceStem: destinationStem) != nil,
              lstat(candidate.path, &backupStat) == 0,
              backupStat.st_mode & S_IFMT == S_IFREG,
              canonicalBackup.deletingLastPathComponent() == canonicalRoot,
              canonicalBackup != canonicalDestination else {
            throw SQLiteBackupError.invalidRestoreSource
        }
        try validateRestoreDestination(canonicalDestination)

        let connection = try SQLiteConnection.readOnly(path: canonicalBackup.path)
        do {
            guard let handle = connection.handle,
                  sqlite3_db_readonly(handle, "main") == 1 else {
                throw SQLiteBackupError.sourceNotReadOnly
            }
            try verifyIntegrity(on: connection)
            return connection
        } catch {
            try? connection.close()
            throw error
        }
    }

    static func applyRestore(
        source: SQLiteConnection,
        destination: URL,
        pageCount: Int32 = -1,
        failAfterSteps: Int? = nil
    ) throws {
        let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        try validateRestoreDestination(canonicalDestination)
        guard let sourceHandle = source.handle,
              sqlite3_db_readonly(sourceHandle, "main") == 1 else {
            throw SQLiteBackupError.sourceNotReadOnly
        }
        try restoreOnline(
            sourceHandle: sourceHandle,
            destination: canonicalDestination,
            pageCount: pageCount,
            failAfterSteps: failAfterSteps
        )
    }

    static func enforceRetention(
        source: URL,
        backupRoot: URL = defaultRoot(),
        keep: Int = retentionCount
    ) throws {
        guard keep >= 1 else { throw SQLiteBackupError.invalidRetention }
        try applyRetention(
            in: backupRoot,
            sourceStem: source.deletingPathExtension().lastPathComponent,
            keep: keep,
            preserving: []
        )
    }

    static func checkpointRestoredDestination(_ destination: URL) throws {
        let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        try validateRestoreDestination(canonicalDestination)
        var handle: OpaquePointer?
        let open = sqlite3_open_v2(canonicalDestination.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard open == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(handle) }
        let checkpoint = sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_FULL, nil, nil)
        guard checkpoint == SQLITE_OK else {
            throw SQLiteBackupError.restoreFailed(checkpoint)
        }
    }

    static func publish(part: URL, final: URL) throws {
        let result = renameatx_np(
            AT_FDCWD,
            part.path,
            AT_FDCWD,
            final.path,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            try? FileManager.default.removeItem(at: part)
            throw SQLiteBackupError.filesystemFailure
        }
    }

    static func verifyIntegrity(of database: URL) throws {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        do {
            try verifyIntegrity(on: connection)
            try connection.close()
        } catch {
            try? connection.close()
            throw error
        }
    }

    static func verifyIntegrity(on connection: SQLiteConnection) throws {
        let statement = try connection.prepare("PRAGMA integrity_check")
        guard try statement.step() else { throw SQLiteBackupError.integrityCheckFailed }
        let row = try SQLiteRow(statement: statement)
        guard try row.text("integrity_check") == "ok", try statement.step() == false else {
            throw SQLiteBackupError.integrityCheckFailed
        }
    }

    private static func copyOnline(sourceHandle: OpaquePointer, to destination: URL) throws {
        var destinationHandle: OpaquePointer?
        let open = sqlite3_open_v2(
            destination.path,
            &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard open == SQLITE_OK, let destinationHandle else {
            if let destinationHandle { sqlite3_close_v2(destinationHandle) }
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(destinationHandle) }

        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw SQLiteBackupError.backupFailed(sqlite3_errcode(destinationHandle))
        }
        var finishNeeded = true
        defer {
            if finishNeeded { sqlite3_backup_finish(backup) }
        }

        var retries = 0
        while true {
            let result = sqlite3_backup_step(backup, -1)
            switch result {
            case SQLITE_DONE:
                let finish = sqlite3_backup_finish(backup)
                finishNeeded = false
                guard finish == SQLITE_OK else { throw SQLiteBackupError.backupFailed(finish) }
                try normalizeBackupArtifact(on: destinationHandle)
                return
            case SQLITE_OK:
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                guard retries < 100 else { throw SQLiteBackupError.backupFailed(result) }
                retries += 1
                sqlite3_sleep(10)
            default:
                throw SQLiteBackupError.backupFailed(result)
            }
        }
    }

    private static func restoreOnline(
        sourceHandle: OpaquePointer,
        destination: URL,
        pageCount: Int32,
        failAfterSteps: Int?
    ) throws {
        var destinationHandle: OpaquePointer?
        let open = sqlite3_open_v2(destination.path, &destinationHandle, SQLITE_OPEN_READWRITE, nil)
        guard open == SQLITE_OK, let destinationHandle else {
            if let destinationHandle { sqlite3_close_v2(destinationHandle) }
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(destinationHandle) }

        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw SQLiteBackupError.restoreFailed(sqlite3_errcode(destinationHandle))
        }
        var finishNeeded = true
        defer {
            if finishNeeded { sqlite3_backup_finish(backup) }
        }

        var retries = 0
        var successfulSteps = 0
        while true {
            let result = sqlite3_backup_step(backup, pageCount)
            switch result {
            case SQLITE_DONE:
                let finish = sqlite3_backup_finish(backup)
                finishNeeded = false
                guard finish == SQLITE_OK else { throw SQLiteBackupError.restoreFailed(finish) }
                return
            case SQLITE_OK:
                successfulSteps += 1
                if failAfterSteps == successfulSteps {
                    throw SQLiteBackupError.restoreFailed(SQLITE_INTERRUPT)
                }
            case SQLITE_BUSY, SQLITE_LOCKED:
                guard retries < 100 else { throw SQLiteBackupError.restoreFailed(result) }
                retries += 1
                sqlite3_sleep(10)
            default:
                throw SQLiteBackupError.restoreFailed(result)
            }
        }
    }

    private static func validateRestoreDestination(_ destination: URL) throws {
        var destinationStat = stat()
        guard lstat(destination.path, &destinationStat) == 0,
              destinationStat.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteBackupError.invalidRestoreDestination
        }
    }

    private static func normalizeBackupArtifact(on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, "PRAGMA journal_mode=DELETE", -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteBackupError.backupFailed(prepare)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text).lowercased() == "delete",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteBackupError.backupFailed(sqlite3_errcode(handle))
        }
    }

    private static func applyRetention(
        in root: URL,
        sourceStem: String,
        keep: Int,
        preserving: Set<String>
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var completed: [(URL, BackupMetadata)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".sqlite.part") {
                let finalName = String(name.dropLast(".part".count))
                if BackupMetadata.parse(filename: finalName, sourceStem: sourceStem) != nil {
                    try FileManager.default.removeItem(at: entry)
                }
                continue
            }
            if let metadata = BackupMetadata.parse(filename: name, sourceStem: sourceStem) {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    completed.append((entry, metadata))
                }
            }
        }

        completed.sort {
            if $0.1.timestamp != $1.1.timestamp { return $0.1.timestamp > $1.1.timestamp }
            return $0.1.uuid.uuidString > $1.1.uuid.uuidString
        }
        for (entry, _) in completed.dropFirst(keep) {
            guard preserving.contains(entry.lastPathComponent) == false else { continue }
            try FileManager.default.removeItem(at: entry)
        }
    }
}
