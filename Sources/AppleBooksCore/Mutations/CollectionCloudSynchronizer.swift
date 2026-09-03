import Darwin
import Foundation

enum CollectionCloudSyncError: Error, Equatable {
    case cloudRecordMissing
    case cloudRecordAmbiguous
    case cloudRecordInvalid
    case serviceRecycleFailed
    case acknowledgementTimedOut
}

struct CollectionCloudSyncState: Equatable {
    let editGeneration: Int64
    let syncGeneration: Int64
    let systemFieldsBytes: Int64

    var isAcknowledged: Bool {
        syncGeneration >= editGeneration && systemFieldsBytes > 0
    }
}

struct CollectionCloudSynchronizer {
    typealias StateAction = (String) throws -> CollectionCloudSyncState?
    typealias RecycleAction = () throws -> Void

    private let booksApp: BooksAppController
    private let stateAction: StateAction
    private let recycleAction: RecycleAction
    private let sleepAction: (TimeInterval) -> Void
    private let pollInterval: TimeInterval
    private let maxPollCount: Int

    init(
        booksApp: BooksAppController,
        stateAction: @escaping StateAction,
        recycleAction: @escaping RecycleAction,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        pollInterval: TimeInterval = 0.1,
        maxPollCount: Int = 600
    ) {
        self.booksApp = booksApp
        self.stateAction = stateAction
        self.recycleAction = recycleAction
        sleepAction = sleep
        self.pollInterval = pollInterval
        self.maxPollCount = maxPollCount
    }

    func sync(collectionID: String) throws {
        guard let initial = try stateAction(collectionID) else {
            throw CollectionCloudSyncError.cloudRecordMissing
        }
        if initial.isAcknowledged { return }

        if booksApp.isRunning() {
            try booksApp.terminateAndWait()
        }
        try recycleAction()
        try booksApp.launch()

        // ponytail: 当前实机 ack 约 13 秒；最多等待 60 秒，若长期超过该上限再改为可配置策略。
        for _ in 0..<maxPollCount {
            guard let state = try stateAction(collectionID) else {
                throw CollectionCloudSyncError.cloudRecordMissing
            }
            if state.isAcknowledged { return }
            sleepAction(pollInterval)
        }
        throw CollectionCloudSyncError.acknowledgementTimedOut
    }

    static func live(
        libraryDatabase: URL,
        booksApp: BooksAppController = .live,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CollectionCloudSynchronizer? {
        guard let location = CollectionCloudStoreLocation.live(
            libraryDatabase: libraryDatabase,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }
        return CollectionCloudSynchronizer(
            booksApp: booksApp,
            stateAction: { try readState(database: location.database, collectionID: $0) },
            recycleAction: liveRecycle
        )
    }

    private static func readState(database: URL, collectionID: String) throws -> CollectionCloudSyncState? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZEDITGENERATION, ZSYNCGENERATION, length(ZCKSYSTEMFIELDS) AS ZSYSTEMFIELDSBYTES
            FROM ZBCCOLLECTIONDETAIL
            WHERE ZCOLLECTIONID=? COLLATE BINARY
            ORDER BY Z_PK
            """)
        try statement.bind(collectionID, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        guard let editGeneration = try row.int64("ZEDITGENERATION"),
              let syncGeneration = try row.int64("ZSYNCGENERATION") else {
            throw CollectionCloudSyncError.cloudRecordInvalid
        }
        let state = CollectionCloudSyncState(
            editGeneration: editGeneration,
            syncGeneration: syncGeneration,
            systemFieldsBytes: try row.int64("ZSYSTEMFIELDSBYTES") ?? 0
        )
        guard try statement.step() == false else {
            throw CollectionCloudSyncError.cloudRecordAmbiguous
        }
        return state
    }

    private static func liveRecycle() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart",
            "-k",
            "gui/\(getuid())/com.apple.bookdatastored",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CollectionCloudSyncError.serviceRecycleFailed
        }
    }
}
