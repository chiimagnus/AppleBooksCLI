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

    func sync(localPK: Int64, onTemporaryBooksLaunch: () -> Void) throws {
        guard let initial = try stateAction(localPK) else { throw AnnotationCloudSyncError.cloudRecordMissing }
        if initial.isAcknowledged { return }
        if booksApp.isRunning() == false {
            try booksApp.launchWithoutActivationAndWait()
            onTemporaryBooksLaunch()
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

    func waitForPendingAcknowledgement() throws {
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

    static func readPendingCount(database: URL) throws -> Int {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT
              COALESCE(SUM(
                CASE
                  WHEN typeof(ZEDITGENERATION) != 'integer'
                    OR typeof(ZSYNCGENERATION) != 'integer'
                    OR typeof(ZCKSYSTEMFIELDS) NOT IN ('null', 'blob')
                  THEN 1 ELSE 0
                END
              ), 0) AS ZINVALIDCOUNT,
              COALESCE(SUM(
                CASE
                  WHEN typeof(ZEDITGENERATION) = 'integer'
                    AND typeof(ZSYNCGENERATION) = 'integer'
                    AND typeof(ZCKSYSTEMFIELDS) IN ('null', 'blob')
                    AND (ZSYNCGENERATION < ZEDITGENERATION
                         OR typeof(ZCKSYSTEMFIELDS) = 'null'
                         OR length(ZCKSYSTEMFIELDS) = 0)
                  THEN 1 ELSE 0
                END
              ), 0) AS ZPENDINGCOUNT
            FROM ZBCASSETANNOTATIONS
            """)
        guard try statement.step() else { throw AnnotationCloudSyncError.cloudRecordInvalid }
        let row = try SQLiteRow(statement: statement)
        guard let invalidCount = try row.int64("ZINVALIDCOUNT"),
              invalidCount == 0,
              let count = try row.int64("ZPENDINGCOUNT"),
              try statement.step() == false else {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
        return Int(count)
    }

    static func readState(database: URL, assetID: String) throws -> AnnotationCloudSyncState? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZEDITGENERATION,
                   ZSYNCGENERATION,
                   CASE typeof(ZCKSYSTEMFIELDS)
                       WHEN 'null' THEN 0
                       WHEN 'blob' THEN length(ZCKSYSTEMFIELDS)
                   END AS ZSYSTEMFIELDSBYTES
            FROM ZBCASSETANNOTATIONS
            WHERE ZASSETID=? COLLATE BINARY
            ORDER BY Z_PK
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        let state: AnnotationCloudSyncState
        do {
            guard let editGeneration = try row.int64("ZEDITGENERATION"),
                  let syncGeneration = try row.int64("ZSYNCGENERATION"),
                  let systemFieldsBytes = try row.int64("ZSYSTEMFIELDSBYTES") else {
                throw AnnotationCloudSyncError.cloudRecordInvalid
            }
            state = AnnotationCloudSyncState(
                editGeneration: editGeneration,
                syncGeneration: syncGeneration,
                systemFieldsBytes: systemFieldsBytes
            )
        } catch {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
        guard try statement.step() == false else { throw AnnotationCloudSyncError.cloudRecordAmbiguous }
        return state
    }
}
