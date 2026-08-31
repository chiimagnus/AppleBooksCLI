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
}

public enum SQLiteBackup {
    public static let retentionCount = 10

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleBooksCLI/backups", isDirectory: true)
    }

    @discardableResult
    public static func create(
        source: URL,
        backupRoot: URL = defaultRoot(),
        keep: Int = retentionCount
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
        try verifyIntegrity(of: part)
        guard rename(part.path, final.path) == 0 else {
            throw SQLiteBackupError.filesystemFailure
        }
        published = true
        do {
            try applyRetention(in: backupRoot, sourceStem: sourceStem, keep: keep)
        } catch {
            throw SQLiteBackupError.retentionFailed
        }
        return final
    }

    static func verifyIntegrity(of database: URL) throws {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        do {
            let statement = try connection.prepare("PRAGMA integrity_check")
            guard try statement.step() else { throw SQLiteBackupError.integrityCheckFailed }
            let row = try SQLiteRow(statement: statement)
            guard try row.text("integrity_check") == "ok", try statement.step() == false else {
                throw SQLiteBackupError.integrityCheckFailed
            }
        }
        try connection.close()
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

    private static func applyRetention(in root: URL, sourceStem: String, keep: Int) throws {
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
            try FileManager.default.removeItem(at: entry)
        }
    }
}
