import Foundation

enum AnnotationCloudSyncError: Error, Equatable {
    case cloudRecordMissing
    case cloudRecordAmbiguous
    case cloudRecordInvalid
    case acknowledgementTimedOut
}

struct AnnotationCloudSyncState: Equatable {
    let editGeneration: Int64
    let syncGeneration: Int64
    let systemFieldsBytes: Int64

    var isAcknowledged: Bool {
        syncGeneration >= editGeneration && systemFieldsBytes > 0
    }
}

struct AnnotationCloudSynchronizer {
    typealias StateAction = (Int64) throws -> AnnotationCloudSyncState?
    typealias PendingCountAction = () throws -> Int

    private let booksApp: BooksAppController
    private let stateAction: StateAction
    private let pendingCountAction: PendingCountAction
    private let sleepAction: (TimeInterval) -> Void
    private let pollInterval: TimeInterval
    private let maxPollCount: Int

    init(
        booksApp: BooksAppController,
        stateAction: @escaping StateAction,
        pendingCount: @escaping PendingCountAction = { 0 },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        pollInterval: TimeInterval = 0.1,
        maxPollCount: Int = 600
    ) {
        self.booksApp = booksApp
        self.stateAction = stateAction
        pendingCountAction = pendingCount
        sleepAction = sleep
        self.pollInterval = pollInterval
        self.maxPollCount = maxPollCount
    }

    func sync(localPK: Int64) throws {
        guard let initial = try stateAction(localPK) else { throw AnnotationCloudSyncError.cloudRecordMissing }
        if initial.isAcknowledged { return }
        if booksApp.isRunning() == false {
            try booksApp.launch()
        }
        // ponytail: annotation projection 已发生在 Books relaunch 之前；只等待 client-side CloudKit ack，不重启系统 daemon。
        try waitUntil {
            guard let state = try stateAction(localPK) else { throw AnnotationCloudSyncError.cloudRecordMissing }
            return state.isAcknowledged
        }
    }

    func pendingCount() throws -> Int {
        try pendingCountAction()
    }

    func syncPending(restartRunningBooks: Bool = false) throws {
        guard try pendingCountAction() > 0 else { return }
        if restartRunningBooks, booksApp.isRunning() {
            try booksApp.terminateAndWait()
            try booksApp.launch()
        } else if booksApp.isRunning() == false {
            try booksApp.launch()
        }
        try waitUntil { try pendingCountAction() == 0 }
    }

    static func live(
        annotationsDatabase: URL,
        booksApp: BooksAppController = .live,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AnnotationCloudSynchronizer? {
        guard let location = AnnotationCloudStoreLocation.live(
            annotationsDatabase: annotationsDatabase,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }
        return AnnotationCloudSynchronizer(
            booksApp: booksApp,
            stateAction: { localPK in
                let identity = try AnnotationCloudProjector.identity(annotationsDatabase: annotationsDatabase, localPK: localPK)
                return try readState(database: location.database, assetID: identity.assetID)
            },
            pendingCount: { try readPendingCount(database: location.database) }
        )
    }

    private func waitUntil(_ condition: () throws -> Bool) throws {
        for _ in 0..<maxPollCount {
            if try condition() { return }
            sleepAction(pollInterval)
        }
        throw AnnotationCloudSyncError.acknowledgementTimedOut
    }

    private static func readPendingCount(database: URL) throws -> Int {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT COUNT(*) AS ZPENDINGCOUNT
            FROM ZBCASSETANNOTATIONS
            WHERE ZSYNCGENERATION < ZEDITGENERATION OR COALESCE(length(ZCKSYSTEMFIELDS), 0) = 0
            """)
        guard try statement.step() else { throw AnnotationCloudSyncError.cloudRecordInvalid }
        let row = try SQLiteRow(statement: statement)
        guard let count = try row.int64("ZPENDINGCOUNT"), count >= 0, count <= Int64(Int.max),
              try statement.step() == false else {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
        return Int(count)
    }

    private static func readState(database: URL, assetID: String) throws -> AnnotationCloudSyncState? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZEDITGENERATION, ZSYNCGENERATION, length(ZCKSYSTEMFIELDS) AS ZSYSTEMFIELDSBYTES
            FROM ZBCASSETANNOTATIONS
            WHERE ZASSETID=? COLLATE BINARY
            ORDER BY Z_PK
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        guard let editGeneration = try row.int64("ZEDITGENERATION"),
              let syncGeneration = try row.int64("ZSYNCGENERATION") else {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
        let state = AnnotationCloudSyncState(
            editGeneration: editGeneration,
            syncGeneration: syncGeneration,
            systemFieldsBytes: try row.int64("ZSYSTEMFIELDSBYTES") ?? 0
        )
        guard try statement.step() == false else { throw AnnotationCloudSyncError.cloudRecordAmbiguous }
        return state
    }
}
