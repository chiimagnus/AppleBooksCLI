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

final class BackupCatalogInstrumentation {
    private(set) var scannedEntryCount = 0
    private(set) var retainedCandidatePeak = 0

    func observeScannedEntry() {
        scannedEntryCount += 1
    }

    func observeRetainedCandidates(_ count: Int) {
        retainedCandidatePeak = max(retainedCandidatePeak, count)
    }
}

final class BackupRetentionInstrumentation {
    private(set) var scannedEntryCount = 0
    private(set) var retainedCandidatePeak = 0

    func observeScannedEntry() {
        scannedEntryCount += 1
    }

    func observeRetainedCandidates(_ count: Int) {
        retainedCandidatePeak = max(retainedCandidatePeak, count)
    }
}

final class BackupRootGuard {
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    let url: URL
    let descriptor: Int32
    private let identity: Identity

    private init(url: URL, descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw SQLiteBackupError.filesystemFailure
        }
        self.url = url
        self.descriptor = descriptor
        identity = Self.identity(metadata)
    }

    deinit {
        close(descriptor)
    }

    static func openExisting(_ rawRoot: URL) throws -> BackupRootGuard? {
        let root = try normalizedRoot(rawRoot)
        guard let descriptor = try openDirectory(root, createMissing: false) else { return nil }
        return try BackupRootGuard(url: root, descriptor: descriptor)
    }

    static func create(_ rawRoot: URL) throws -> BackupRootGuard {
        let root = try normalizedRoot(rawRoot)
        guard let descriptor = try openDirectory(root, createMissing: true) else {
            throw SQLiteBackupError.filesystemFailure
        }
        return try BackupRootGuard(url: root, descriptor: descriptor)
    }

    static func isReady(_ rawRoot: URL) -> Bool {
        do {
            let root = try normalizedRoot(rawRoot)
            let components = pathComponents(root)
            var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }

            for component in components {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0 {
                    guard errno == ENOENT,
                          faccessat(descriptor, ".", W_OK | X_OK, 0) == 0 else {
                        return false
                    }
                    return true
                }
                close(descriptor)
                descriptor = next
            }
            return faccessat(descriptor, ".", W_OK | X_OK, 0) == 0
        } catch {
            return false
        }
    }

    func validateCurrentPathIdentity() throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Self.identity(metadata) == identity else {
            throw SQLiteBackupError.filesystemFailure
        }
    }

    func withExclusiveMutationLock<T>(_ body: () throws -> T) throws -> T {
        try validateCurrentPathIdentity()
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SQLiteBackupError.filesystemFailure }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try validateCurrentPathIdentity()
        let result = try body()
        try validateCurrentPathIdentity()
        return result
    }

    func forEachEntryName(_ body: (String) throws -> Void) throws {
        try validateCurrentPathIdentity()
        let enumerationFD = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard enumerationFD >= 0 else { throw SQLiteBackupError.filesystemFailure }
        guard let directory = fdopendir(enumerationFD) else {
            close(enumerationFD)
            throw SQLiteBackupError.filesystemFailure
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw SQLiteBackupError.filesystemFailure }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            try body(name)
        }
        try validateCurrentPathIdentity()
    }

    func entryStat(_ name: String) throws -> stat? {
        var metadata = stat()
        if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return metadata
        }
        if errno == ENOENT { return nil }
        throw SQLiteBackupError.filesystemFailure
    }

    func openRegularFile(_ name: String) throws -> Int32 {
        try validateCurrentPathIdentity()
        let fileDescriptor = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { throw SQLiteBackupError.invalidRestoreSource }
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            close(fileDescriptor)
            throw SQLiteBackupError.invalidRestoreSource
        }
        return fileDescriptor
    }

    func removeRegularFile(named name: String) throws {
        try validateCurrentPathIdentity()
        guard let metadata = try entryStat(name), metadata.st_mode & S_IFMT == S_IFREG else { return }
        guard unlinkat(descriptor, name, 0) == 0 else { throw SQLiteBackupError.filesystemFailure }
        try validateCurrentPathIdentity()
    }

    func publish(staging: URL, finalName: String) throws {
        try validateCurrentPathIdentity()
        let partName = finalName + ".part"
        let sourceFD = open(staging.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw SQLiteBackupError.filesystemFailure }
        defer { close(sourceFD) }

        let partFD = openat(
            descriptor,
            partName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard partFD >= 0 else { throw SQLiteBackupError.filesystemFailure }
        var published = false
        defer {
            close(partFD)
            if published == false { _ = unlinkat(descriptor, partName, 0) }
        }

        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(sourceFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SQLiteBackupError.filesystemFailure
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(partFD, rawBuffer.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SQLiteBackupError.filesystemFailure
                }
                guard written > 0 else { throw SQLiteBackupError.filesystemFailure }
                offset += written
            }
        }
        guard fsync(partFD) == 0 else { throw SQLiteBackupError.filesystemFailure }
        try validateCurrentPathIdentity()
        guard renameatx_np(
            descriptor,
            partName,
            descriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0,
        fsync(descriptor) == 0 else {
            throw SQLiteBackupError.filesystemFailure
        }
        published = true
        try validateCurrentPathIdentity()
    }

    private static func normalizedRoot(_ rawRoot: URL) throws -> URL {
        guard rawRoot.isFileURL else { throw SQLiteBackupError.filesystemFailure }
        let standardized = rawRoot.standardizedFileURL
        let path = standardized.path
        let authorized: URL
        if path == "/var" || path.hasPrefix("/var/") {
            authorized = URL(fileURLWithPath: "/private" + path, isDirectory: true)
        } else {
            authorized = standardized
        }
        guard authorized.path.hasPrefix("/"), authorized.path != "/" else {
            throw SQLiteBackupError.filesystemFailure
        }
        return authorized
    }

    private static func pathComponents(_ root: URL) -> [String] {
        root.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func openDirectory(_ root: URL, createMissing: Bool) throws -> Int32? {
        let components = pathComponents(root)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteBackupError.filesystemFailure }
        var ownsDescriptor = true
        defer { if ownsDescriptor { close(descriptor) } }

        for component in components {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                guard createMissing else { return nil }
                guard faccessat(descriptor, ".", W_OK | X_OK, 0) == 0,
                      mkdirat(descriptor, component, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
                    throw SQLiteBackupError.filesystemFailure
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw SQLiteBackupError.filesystemFailure }
            close(descriptor)
            descriptor = next
        }
        ownsDescriptor = false
        return descriptor
    }

    private static func identity(_ metadata: stat) -> Identity {
        Identity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino)
        )
    }
}

public enum SQLiteBackup {
    public static let retentionCount = 10

    private struct CatalogCandidate {
        let backup: LibraryBackup
        let metadata: BackupMetadata
    }

    private struct RetentionCandidate {
        let name: String
        let metadata: BackupMetadata
    }

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleBooksCLI/backups", isDirectory: true)
    }

    static func list(
        source: URL,
        backupRoot: URL = defaultRoot(),
        instrumentation: BackupCatalogInstrumentation? = nil
    ) throws -> [LibraryBackup] {
        guard let root = try BackupRootGuard.openExisting(backupRoot) else { return [] }
        let sourceStem = source.deletingPathExtension().lastPathComponent
        var candidates: [CatalogCandidate] = []
        candidates.reserveCapacity(retentionCount)

        try root.forEachEntryName { name in
            instrumentation?.observeScannedEntry()
            guard let metadata = BackupMetadata.parse(filename: name, sourceStem: sourceStem),
                  metadata.filename == name,
                  let entryStat = try root.entryStat(name),
                  entryStat.st_mode & S_IFMT == S_IFREG,
                  entryStat.st_size >= 0 else {
                return
            }

            retainCatalogCandidate(
                CatalogCandidate(
                    backup: LibraryBackup(
                        handle: name,
                        backupID: metadata.backupID,
                        createdAt: metadata.timestamp,
                        sizeBytes: Int64(entryStat.st_size)
                    ),
                    metadata: metadata
                ),
                in: &candidates
            )
            instrumentation?.observeRetainedCandidates(candidates.count)
        }

        return candidates.map(\.backup)
    }

    private static func retainCatalogCandidate(
        _ candidate: CatalogCandidate,
        in candidates: inout [CatalogCandidate]
    ) {
        let insertion = candidates.firstIndex { catalogPrecedes(candidate, $0) } ?? candidates.endIndex
        if candidates.count < retentionCount {
            candidates.insert(candidate, at: insertion)
            return
        }
        guard insertion < candidates.endIndex else { return }
        candidates.insert(candidate, at: insertion)
        candidates.removeLast()
    }

    private static func catalogPrecedes(_ lhs: CatalogCandidate, _ rhs: CatalogCandidate) -> Bool {
        if lhs.metadata.timestamp != rhs.metadata.timestamp {
            return lhs.metadata.timestamp > rhs.metadata.timestamp
        }
        return lhs.metadata.uuid.uuidString > rhs.metadata.uuid.uuidString
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

        let root = try BackupRootGuard.create(backupRoot)
        let sourceStem = source.deletingPathExtension().lastPathComponent
        let metadata = BackupMetadata.fresh(sourceStem: sourceStem)

        try withTemporaryBackupDatabase { staging in
            try copyOnline(sourceHandle: sourceHandle, to: staging)
            try sourceConnection.close()
            try verifyIntegrity(of: staging)
            try root.withExclusiveMutationLock {
                try root.publish(staging: staging, finalName: metadata.filename)
                do {
                    try applyRetention(
                        in: root,
                        sourceStem: sourceStem,
                        keep: keep,
                        preserving: preserving
                    )
                } catch {
                    throw SQLiteBackupError.retentionFailed
                }
            }
        }
        try root.validateCurrentPathIdentity()
        return root.url.appendingPathComponent(metadata.filename, isDirectory: false)
    }

    static func restoreHandle(backupID: String, destination: URL) throws -> String {
        let destinationStem = destination.deletingPathExtension().lastPathComponent
        guard let metadata = BackupMetadata.parse(backupID: backupID, sourceStem: destinationStem) else {
            throw LibraryBackupIdentityError.invalidBackupID
        }
        return metadata.filename
    }

    static func openRestoreSource(
        handle: String,
        destination: URL,
        backupRoot: URL = defaultRoot()
    ) throws -> SQLiteConnection {
        let destinationStem = destination.deletingPathExtension().lastPathComponent
        guard BackupMetadata.parse(filename: handle, sourceStem: destinationStem) != nil,
              let root = try BackupRootGuard.openExisting(backupRoot) else {
            throw SQLiteBackupError.invalidRestoreSource
        }
        try validateRestoreDestination(destination)

        let sourceFD = try root.openRegularFile(handle)
        defer { close(sourceFD) }
        var sourceStat = stat()
        var destinationStat = stat()
        guard fstat(sourceFD, &sourceStat) == 0,
              lstat(destination.path, &destinationStat) == 0,
              sourceStat.st_dev != destinationStat.st_dev || sourceStat.st_ino != destinationStat.st_ino else {
            throw SQLiteBackupError.invalidRestoreSource
        }

        let connection = try SQLiteConnection.readOnly(path: "/dev/fd/\(sourceFD)")
        do {
            guard let sqliteHandle = connection.handle,
                  sqlite3_db_readonly(sqliteHandle, "main") == 1 else {
                throw SQLiteBackupError.sourceNotReadOnly
            }
            try verifyIntegrity(on: connection)
            try root.validateCurrentPathIdentity()
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
        keep: Int = retentionCount,
        preserving: Set<String> = [],
        instrumentation: BackupRetentionInstrumentation? = nil,
        betweenPasses: (() throws -> Void)? = nil
    ) throws {
        guard keep >= 1 else { throw SQLiteBackupError.invalidRetention }
        guard let root = try BackupRootGuard.openExisting(backupRoot) else {
            throw SQLiteBackupError.filesystemFailure
        }
        try root.withExclusiveMutationLock {
            try applyRetention(
                in: root,
                sourceStem: source.deletingPathExtension().lastPathComponent,
                keep: keep,
                preserving: preserving,
                instrumentation: instrumentation,
                betweenPasses: betweenPasses
            )
        }
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
        in root: BackupRootGuard,
        sourceStem: String,
        keep: Int,
        preserving: Set<String>,
        instrumentation: BackupRetentionInstrumentation? = nil,
        betweenPasses: (() throws -> Void)? = nil
    ) throws {
        var newest: [RetentionCandidate] = []
        newest.reserveCapacity(keep)

        try root.forEachEntryName { name in
            instrumentation?.observeScannedEntry()
            if name.hasSuffix(".sqlite.part") {
                let finalName = String(name.dropLast(".part".count))
                if BackupMetadata.parse(filename: finalName, sourceStem: sourceStem) != nil {
                    try root.removeRegularFile(named: name)
                }
                return
            }
            guard let metadata = BackupMetadata.parse(filename: name, sourceStem: sourceStem),
                  let entryStat = try root.entryStat(name),
                  entryStat.st_mode & S_IFMT == S_IFREG else {
                return
            }
            retainRetentionCandidate(
                RetentionCandidate(name: name, metadata: metadata),
                keep: keep,
                in: &newest
            )
            instrumentation?.observeRetainedCandidates(newest.count)
        }

        try betweenPasses?()
        let retainedNames = Set(newest.map(\.name)).union(preserving)
        let retentionCutoff = newest.count == keep ? newest.last : nil
        try root.forEachEntryName { name in
            instrumentation?.observeScannedEntry()
            guard retainedNames.contains(name) == false,
                  let metadata = BackupMetadata.parse(filename: name, sourceStem: sourceStem),
                  let entryStat = try root.entryStat(name),
                  entryStat.st_mode & S_IFMT == S_IFREG,
                  let retentionCutoff,
                  retentionPrecedes(retentionCutoff, RetentionCandidate(name: name, metadata: metadata)) else {
                return
            }
            try root.removeRegularFile(named: name)
        }
        try root.validateCurrentPathIdentity()
    }

    private static func retainRetentionCandidate(
        _ candidate: RetentionCandidate,
        keep: Int,
        in candidates: inout [RetentionCandidate]
    ) {
        let insertion = candidates.firstIndex { retentionPrecedes(candidate, $0) } ?? candidates.endIndex
        if candidates.count < keep {
            candidates.insert(candidate, at: insertion)
            return
        }
        guard insertion < candidates.endIndex else { return }
        candidates.insert(candidate, at: insertion)
        candidates.removeLast()
    }

    private static func retentionPrecedes(_ lhs: RetentionCandidate, _ rhs: RetentionCandidate) -> Bool {
        if lhs.metadata.timestamp != rhs.metadata.timestamp {
            return lhs.metadata.timestamp > rhs.metadata.timestamp
        }
        return lhs.metadata.uuid.uuidString > rhs.metadata.uuid.uuidString
    }

    private static func withTemporaryBackupDatabase<T>(_ body: (URL) throws -> T) throws -> T {
        let templatePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-backup-XXXXXX", isDirectory: true)
            .path
        var template = Array(templatePath.utf8CString)
        let directoryPath: String = try template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, let created = mkdtemp(base) else {
                throw SQLiteBackupError.filesystemFailure
            }
            return String(cString: created)
        }
        let database = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("backup.sqlite", isDirectory: false)
        defer {
            _ = unlink(database.path)
            _ = unlink(database.path + "-wal")
            _ = unlink(database.path + "-shm")
            _ = unlink(database.path + "-journal")
            _ = rmdir(directoryPath)
        }
        return try body(database)
    }
}
