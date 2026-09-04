import Darwin
import Foundation

enum OperationHistoryStoreError: Error, Equatable {
    case unavailable
}

enum OperationHistoryStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
    case incomplete
}

struct OperationHistoryRecord: Equatable, Sendable {
    let id: String
    let operation: String
    let arguments: [String]
    let startedAt: Date
    let completedAt: Date?
    let exitCode: Int32?
    let stdout: String?
    let stderr: String?
    let status: OperationHistoryStatus

    fileprivate let fileName: String
}

struct OperationHistoryToken: Equatable, Sendable {
    let id: String
    let startedAt: Date
    fileprivate let fileName: String
}

struct OperationHistoryStore: Sendable {
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    static let schemaVersion = 1
    private static let lockFileName = ".lock"
    private static let temporaryPrefix = ".operation-history-"
    private static let temporarySuffix = ".tmp"
    private static let directoryMode = mode_t(S_IRWXU)
    private static let fileMode = mode_t(S_IRUSR | S_IWUSR)
    // ponytail: 单进程单锁 + root 文件锁并全量扫描 24h 记录；若真实并发/记录量成为瓶颈，再按 root 细分并加索引。
    private static let processLock = NSLock()

    private let root: URL
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    init(
        root: URL = Self.defaultRoot(),
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        let standardized = root.standardizedFileURL
        let canonicalParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        self.root = canonicalParent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
        self.now = now
        self.timeZone = timeZone
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleBooksCLI/history", isDirectory: true)
    }

    func begin(operation: String, arguments: [String]) throws -> OperationHistoryToken {
        guard operation.isEmpty == false else { throw OperationHistoryStoreError.unavailable }
        let startedAt = Self.historyTimestamp(now())
        let result = try withLockedRoot(createIfMissing: true) { rootFD in
            let records = try prune(rootFD: rootFD, reference: startedAt)
            var id: String
            repeat {
                id = UUID().uuidString.lowercased()
            } while records.contains { $0.id == id }

            let fileName = Self.dateFileName(for: startedAt, timeZone: timeZone())
            let event = OperationHistoryEvent.started(
                id: id,
                operation: operation,
                arguments: arguments,
                startedAt: startedAt
            )
            try append(event, to: fileName, rootFD: rootFD)
            return OperationHistoryToken(id: id, startedAt: startedAt, fileName: fileName)
        }
        guard case let .value(token) = result else { throw OperationHistoryStoreError.unavailable }
        return token
    }

    func complete(
        _ token: OperationHistoryToken,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) throws {
        let completedAt = Self.historyTimestamp(now())
        let cutoff = completedAt.addingTimeInterval(-Self.retentionInterval)
        if token.startedAt < cutoff {
            _ = try withLockedRoot(createIfMissing: false) { rootFD in
                _ = try prune(rootFD: rootFD, reference: completedAt)
            }
            return
        }

        let result = try withLockedRoot(createIfMissing: false) { rootFD in
            let records = try prune(rootFD: rootFD, reference: completedAt)
            guard let record = records.first(where: { $0.id == token.id }),
                  record.status == .incomplete,
                  record.startedAt == token.startedAt,
                  record.fileName == token.fileName else {
                throw OperationHistoryStoreError.unavailable
            }
            let event = OperationHistoryEvent.completed(
                id: token.id,
                completedAt: completedAt,
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr
            )
            try append(event, to: token.fileName, rootFD: rootFD)
        }
        guard case .value = result else { throw OperationHistoryStoreError.unavailable }
    }

    func list() throws -> [OperationHistoryRecord] {
        let reference = Self.historyTimestamp(now())
        switch try withLockedRoot(createIfMissing: false, { rootFD in
            try prune(rootFD: rootFD, reference: reference)
        }) {
        case .missing:
            return []
        case let .value(records):
            return records.sorted(by: Self.recordOrder)
        }
    }

    func get(id: String) throws -> OperationHistoryRecord? {
        let reference = Self.historyTimestamp(now())
        switch try withLockedRoot(createIfMissing: false, { rootFD in
            try prune(rootFD: rootFD, reference: reference)
        }) {
        case .missing:
            return nil
        case let .value(records):
            return records.first { $0.id == id }
        }
    }

    private func prune(rootFD: Int32, reference: Date) throws -> [OperationHistoryRecord] {
        try cleanupStaleTemporaryFiles(rootFD: rootFD)
        let loaded = try load(rootFD: rootFD)
        let records = try fold(loaded.lines)
        let cutoff = reference.addingTimeInterval(-Self.retentionInterval)
        let keptRecords = records.filter { $0.startedAt >= cutoff }
        let keptIDs = Set(keptRecords.map(\.id))

        for fileName in loaded.fileNames {
            let current = loaded.lines.filter { $0.fileName == fileName }
            let retained = current.filter { keptIDs.contains($0.event.id) }
            if retained.isEmpty {
                try removeControlledFile(fileName, rootFD: rootFD)
            } else if retained.count != current.count {
                var data = Data()
                for line in retained { data.append(line.rawLine) }
                try replaceControlledFile(fileName, with: data, rootFD: rootFD)
            }
        }
        return keptRecords
    }

    private func load(rootFD: Int32) throws -> LoadedHistory {
        let names = try directoryNames(rootFD: rootFD).filter(Self.isDateFileName).sorted()
        var lines: [StoredLine] = []
        for name in names {
            lines.append(contentsOf: try readAndRepair(name, rootFD: rootFD))
        }
        return LoadedHistory(fileNames: names, lines: lines)
    }

    private func fold(_ lines: [StoredLine]) throws -> [OperationHistoryRecord] {
        var states: [String: FoldState] = [:]
        for line in lines {
            let event = line.event
            switch event.kind {
            case .started:
                guard states[event.id] == nil,
                      let operation = event.operation,
                      let arguments = event.arguments,
                      let startedAt = event.startedAt else {
                    throw OperationHistoryStoreError.unavailable
                }
                states[event.id] = FoldState(
                    operation: operation,
                    arguments: arguments,
                    startedAt: startedAt,
                    fileName: line.fileName,
                    completed: nil
                )
            case .completed:
                guard var state = states[event.id],
                      state.fileName == line.fileName,
                      state.completed == nil,
                      let completedAt = event.completedAt,
                      let exitCode = event.exitCode,
                      let stdout = event.stdout,
                      let stderr = event.stderr else {
                    throw OperationHistoryStoreError.unavailable
                }
                state.completed = CompletedState(
                    completedAt: completedAt,
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr
                )
                states[event.id] = state
            }
        }

        return states.map { id, state in
            let completed = state.completed
            return OperationHistoryRecord(
                id: id,
                operation: state.operation,
                arguments: state.arguments,
                startedAt: state.startedAt,
                completedAt: completed?.completedAt,
                exitCode: completed?.exitCode,
                stdout: completed?.stdout,
                stderr: completed?.stderr,
                status: completed.map { $0.exitCode == 0 ? .success : .failure } ?? .incomplete,
                fileName: state.fileName
            )
        }
    }

    private func append(_ event: OperationHistoryEvent, to fileName: String, rootFD: Int32) throws {
        guard Self.isDateFileName(fileName) else { throw OperationHistoryStoreError.unavailable }
        let fd = openat(
            rootFD,
            fileName,
            O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(fd) }
        try secureRegularFile(fd)

        var data = try Self.encoder().encode(event)
        data.append(0x0A)
        try Self.writeAll(data, to: fd)
        guard fsync(fd) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func readAndRepair(_ fileName: String, rootFD: Int32) throws -> [StoredLine] {
        let fd = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(fd) }
        try secureRegularFile(fd)

        var data = try Self.readAll(from: fd)
        if data.isEmpty == false, data.last != 0x0A {
            let completeLength = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            guard ftruncate(fd, off_t(completeLength)) == 0,
                  fsync(fd) == 0 else {
                throw OperationHistoryStoreError.unavailable
            }
            data = Data(data.prefix(completeLength))
        }
        guard data.isEmpty == false else { return [] }

        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        var lines: [StoredLine] = []
        for part in parts {
            guard part.isEmpty == false else { throw OperationHistoryStoreError.unavailable }
            let raw = Data(part)
            let event: OperationHistoryEvent
            do {
                event = try Self.decoder().decode(OperationHistoryEvent.self, from: raw)
            } catch {
                throw OperationHistoryStoreError.unavailable
            }
            try event.validate()
            var rawLine = raw
            rawLine.append(0x0A)
            lines.append(StoredLine(fileName: fileName, event: event, rawLine: rawLine))
        }
        return lines
    }

    private func cleanupStaleTemporaryFiles(rootFD: Int32) throws {
        for name in try directoryNames(rootFD: rootFD).filter(Self.isTemporaryFileName).sorted() {
            let fd = openat(rootFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
            do {
                try secureRegularFile(fd)
            } catch {
                Darwin.close(fd)
                throw error
            }
            Darwin.close(fd)
            guard unlinkat(rootFD, name, 0) == 0 else { throw OperationHistoryStoreError.unavailable }
        }
    }

    private func removeControlledFile(_ fileName: String, rootFD: Int32) throws {
        let fd = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureRegularFile(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        Darwin.close(fd)
        guard unlinkat(rootFD, fileName, 0) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func replaceControlledFile(_ fileName: String, with data: Data, rootFD: Int32) throws {
        let temporaryName = Self.temporaryFileName()
        let temporaryFD = openat(
            rootFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard temporaryFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        var temporaryExists = true
        defer {
            Darwin.close(temporaryFD)
            if temporaryExists { _ = unlinkat(rootFD, temporaryName, 0) }
        }
        try secureRegularFile(temporaryFD)
        try Self.writeAll(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else { throw OperationHistoryStoreError.unavailable }

        let destinationFD = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard destinationFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureRegularFile(destinationFD)
        } catch {
            Darwin.close(destinationFD)
            throw error
        }
        Darwin.close(destinationFD)

        guard renameat(rootFD, temporaryName, rootFD, fileName) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
        temporaryExists = false
    }

    private func directoryNames(rootFD: Int32) throws -> [String] {
        let directoryFD = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        guard let directory = fdopendir(directoryFD) else {
            Darwin.close(directoryFD)
            throw OperationHistoryStoreError.unavailable
        }
        defer { closedir(directory) }

        errno = 0
        var names: [String] = []
        while let pointer = readdir(directory) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) { value in
                value.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw OperationHistoryStoreError.unavailable }
        return names
    }

    private func withLockedRoot<Value>(
        createIfMissing: Bool,
        _ body: (Int32) throws -> Value
    ) throws -> LockedRootResult<Value> {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let rootFD = try openRoot(createIfMissing: createIfMissing) else { return .missing }
        defer { Darwin.close(rootFD) }

        let lockFD = openat(
            rootFD,
            Self.lockFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK,
            Self.fileMode
        )
        guard lockFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(lockFD) }
        try secureRegularFile(lockFD)
        let value = try body(rootFD)
        try validateRootIdentity(rootFD)
        return .value(value)
    }

    private func openRoot(createIfMissing: Bool) throws -> Int32? {
        var rootStat = stat()
        if lstat(root.path, &rootStat) != 0 {
            guard errno == ENOENT else { throw OperationHistoryStoreError.unavailable }
            guard createIfMissing else { return nil }
            let parent = root.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw OperationHistoryStoreError.unavailable
            }
            guard parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else {
                throw OperationHistoryStoreError.unavailable
            }
            if mkdir(root.path, Self.directoryMode) != 0, errno != EEXIST {
                throw OperationHistoryStoreError.unavailable
            }
        }

        guard root.resolvingSymlinksInPath().path == root.path else {
            throw OperationHistoryStoreError.unavailable
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureDirectory(fd)
            try validateRootIdentity(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func validateRootIdentity(_ fd: Int32) throws {
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0,
              lstat(root.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              current.st_uid == geteuid(),
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func secureDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else {
            throw OperationHistoryStoreError.unavailable
        }
        if info.st_mode & mode_t(0o777) != Self.directoryMode {
            guard fchmod(fd, Self.directoryMode) == 0 else { throw OperationHistoryStoreError.unavailable }
            var checked = stat()
            guard fstat(fd, &checked) == 0,
                  checked.st_mode & mode_t(0o777) == Self.directoryMode,
                  checked.st_uid == geteuid() else {
                throw OperationHistoryStoreError.unavailable
            }
        }
    }

    private func secureRegularFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid() else {
            throw OperationHistoryStoreError.unavailable
        }
        if info.st_mode & mode_t(0o777) != Self.fileMode {
            guard fchmod(fd, Self.fileMode) == 0 else { throw OperationHistoryStoreError.unavailable }
            var checked = stat()
            guard fstat(fd, &checked) == 0,
                  checked.st_mode & mode_t(0o777) == Self.fileMode,
                  checked.st_uid == geteuid() else {
                throw OperationHistoryStoreError.unavailable
            }
        }
    }

    private static func readAll(from fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw OperationHistoryStoreError.unavailable }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw OperationHistoryStoreError.unavailable
            }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw OperationHistoryStoreError.unavailable
                }
            }
        }
    }

    private static func historyTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private static func dateFileName(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d.jsonl",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func isDateFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".jsonl") else { return false }
        let date = String(name.dropLast(".jsonl".count))
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard date.utf8.count == 10,
              parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9999).contains(year) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let value = calendar.date(from: components) else { return false }
        let checked = calendar.dateComponents([.year, .month, .day], from: value)
        return checked.year == year && checked.month == month && checked.day == day
    }

    private static func temporaryFileName() -> String {
        temporaryPrefix + UUID().uuidString.lowercased() + temporarySuffix
    }

    private static func isTemporaryFileName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: temporaryPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -temporarySuffix.count)
        let rawID = String(name[start..<end])
        guard let uuid = UUID(uuidString: rawID) else { return false }
        return rawID == uuid.uuidString.lowercased()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func recordOrder(_ lhs: OperationHistoryRecord, _ rhs: OperationHistoryRecord) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id < rhs.id
    }
}

private struct OperationHistoryEvent: Codable {
    enum Kind: String, Codable {
        case started
        case completed
    }

    let schemaVersion: Int
    let kind: Kind
    let id: String
    let operation: String?
    let arguments: [String]?
    let startedAt: Date?
    let completedAt: Date?
    let exitCode: Int32?
    let stdout: String?
    let stderr: String?

    static func started(id: String, operation: String, arguments: [String], startedAt: Date) -> Self {
        Self(
            schemaVersion: OperationHistoryStore.schemaVersion,
            kind: .started,
            id: id,
            operation: operation,
            arguments: arguments,
            startedAt: startedAt,
            completedAt: nil,
            exitCode: nil,
            stdout: nil,
            stderr: nil
        )
    }

    static func completed(id: String, completedAt: Date, exitCode: Int32, stdout: String, stderr: String) -> Self {
        Self(
            schemaVersion: OperationHistoryStore.schemaVersion,
            kind: .completed,
            id: id,
            operation: nil,
            arguments: nil,
            startedAt: nil,
            completedAt: completedAt,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    func validate() throws {
        guard schemaVersion == OperationHistoryStore.schemaVersion,
              let uuid = UUID(uuidString: id),
              id == uuid.uuidString.lowercased() else {
            throw OperationHistoryStoreError.unavailable
        }
        switch kind {
        case .started:
            guard let operation, operation.isEmpty == false,
                  arguments != nil,
                  startedAt != nil,
                  completedAt == nil,
                  exitCode == nil,
                  stdout == nil,
                  stderr == nil else {
                throw OperationHistoryStoreError.unavailable
            }
        case .completed:
            guard operation == nil,
                  arguments == nil,
                  startedAt == nil,
                  completedAt != nil,
                  exitCode != nil,
                  stdout != nil,
                  stderr != nil else {
                throw OperationHistoryStoreError.unavailable
            }
        }
    }
}

private struct StoredLine {
    let fileName: String
    let event: OperationHistoryEvent
    let rawLine: Data
}

private struct LoadedHistory {
    let fileNames: [String]
    let lines: [StoredLine]
}

private struct CompletedState {
    let completedAt: Date
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct FoldState {
    let operation: String
    let arguments: [String]
    let startedAt: Date
    let fileName: String
    var completed: CompletedState?
}

private enum LockedRootResult<Value> {
    case missing
    case value(Value)
}
