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
    let deleted: Bool
    let editGeneration: Int64
    let syncGeneration: Int64
    let systemFieldsBytes: Int64

    var isAcknowledged: Bool {
        syncGeneration >= editGeneration && systemFieldsBytes > 0
    }
}

struct CollectionCloudSynchronizer {
    typealias DetailStateAction = (Int64) throws -> CollectionCloudSyncState?
    typealias MemberStateAction = (Int64, String) throws -> CollectionCloudSyncState?
    typealias DeletedMemberStatesAction = (Int64) throws -> [CollectionCloudSyncState]
    typealias RecycleAction = () throws -> Void

    private let booksApp: BooksAppController
    private let detailStateAction: DetailStateAction
    private let memberStateAction: MemberStateAction
    private let deletedMemberStatesAction: DeletedMemberStatesAction
    private let recycleAction: RecycleAction
    private let sleepAction: (TimeInterval) -> Void
    private let pollInterval: TimeInterval
    private let maxPollCount: Int

    init(
        booksApp: BooksAppController,
        detailState: @escaping DetailStateAction,
        memberState: @escaping MemberStateAction,
        deletedMemberStates: @escaping DeletedMemberStatesAction,
        recycleAction: @escaping RecycleAction,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        pollInterval: TimeInterval = 0.1,
        maxPollCount: Int = 600
    ) {
        self.booksApp = booksApp
        detailStateAction = detailState
        memberStateAction = memberState
        deletedMemberStatesAction = deletedMemberStates
        self.recycleAction = recycleAction
        sleepAction = sleep
        self.pollInterval = pollInterval
        self.maxPollCount = maxPollCount
    }

    func syncCollection(localPK: Int64, deleting: Bool = false) throws {
        if try collectionSatisfied(localPK: localPK, deleting: deleting) { return }
        try triggerSync()
        try waitUntil { try collectionSatisfied(localPK: localPK, deleting: deleting) }
    }

    func syncMembership(collectionLocalPK: Int64, assetID: String, deleting: Bool) throws {
        if try membershipSatisfied(collectionLocalPK: collectionLocalPK, assetID: assetID, deleting: deleting) { return }
        try triggerSync()
        try waitUntil {
            try membershipSatisfied(collectionLocalPK: collectionLocalPK, assetID: assetID, deleting: deleting)
        }
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
            detailState: {
                let collectionID = try CollectionCloudProjector.collectionID(libraryDatabase: libraryDatabase, localPK: $0)
                return try readState(database: location.database, table: "ZBCCOLLECTIONDETAIL", identityColumn: "ZCOLLECTIONID", identity: collectionID)
            },
            memberState: { localPK, assetID in
                let collectionID = try CollectionCloudProjector.collectionID(libraryDatabase: libraryDatabase, localPK: localPK)
                return try readState(database: location.database, table: "ZBCCOLLECTIONMEMBER", identityColumn: "ZCOLLECTIONMEMBERID", identity: "\(collectionID)|\(assetID)")
            },
            deletedMemberStates: { localPK in
                let collectionID = try CollectionCloudProjector.collectionID(libraryDatabase: libraryDatabase, localPK: localPK)
                return try readMemberStates(database: location.database, collectionID: collectionID)
            },
            recycleAction: liveRecycle
        )
    }

    private func collectionSatisfied(localPK: Int64, deleting: Bool) throws -> Bool {
        let detail = try detailStateAction(localPK)
        if deleting {
            guard detail == nil || (detail?.deleted == true && detail?.isAcknowledged == true) else { return false }
            return try deletedMemberStatesAction(localPK).allSatisfy { $0.deleted && $0.isAcknowledged }
        }
        guard let detail else { throw CollectionCloudSyncError.cloudRecordMissing }
        return detail.deleted == false && detail.isAcknowledged
    }

    private func membershipSatisfied(collectionLocalPK: Int64, assetID: String, deleting: Bool) throws -> Bool {
        guard let detail = try detailStateAction(collectionLocalPK) else {
            throw CollectionCloudSyncError.cloudRecordMissing
        }
        guard detail.deleted == false, detail.isAcknowledged else { return false }
        let member = try memberStateAction(collectionLocalPK, assetID)
        if deleting {
            return member == nil || (member?.deleted == true && member?.isAcknowledged == true)
        }
        guard let member else { throw CollectionCloudSyncError.cloudRecordMissing }
        return member.deleted == false && member.isAcknowledged
    }

    private func triggerSync() throws {
        if booksApp.isRunning() {
            try booksApp.terminateAndWait()
        }
        try recycleAction()
        try booksApp.launch()
    }

    private func waitUntil(_ condition: () throws -> Bool) throws {
        // ponytail: 当前实机 collection ack 最慢约十余秒；保留 60 秒上限，超出时失败关闭。
        for _ in 0..<maxPollCount {
            if try condition() { return }
            sleepAction(pollInterval)
        }
        throw CollectionCloudSyncError.acknowledgementTimedOut
    }

    private static func readState(
        database: URL,
        table: String,
        identityColumn: String,
        identity: String
    ) throws -> CollectionCloudSyncState? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZDELETEDFLAG, ZEDITGENERATION, ZSYNCGENERATION, length(ZCKSYSTEMFIELDS) AS ZSYSTEMFIELDSBYTES
            FROM \(table)
            WHERE \(identityColumn)=? COLLATE BINARY
            ORDER BY Z_PK
            """)
        try statement.bind(identity, at: 1)
        guard try statement.step() else { return nil }
        let state = try state(from: SQLiteRow(statement: statement))
        guard try statement.step() == false else { throw CollectionCloudSyncError.cloudRecordAmbiguous }
        return state
    }

    private static func readMemberStates(database: URL, collectionID: String) throws -> [CollectionCloudSyncState] {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZDELETEDFLAG, ZEDITGENERATION, ZSYNCGENERATION, length(ZCKSYSTEMFIELDS) AS ZSYSTEMFIELDSBYTES
            FROM ZBCCOLLECTIONMEMBER
            WHERE ZCOLLECTIONMEMBERID LIKE ? ESCAPE '\\'
            ORDER BY Z_PK
            """)
        let escaped = collectionID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        try statement.bind("\(escaped)|%", at: 1)
        var states: [CollectionCloudSyncState] = []
        while try statement.step() {
            states.append(try state(from: SQLiteRow(statement: statement)))
        }
        return states
    }

    private static func state(from row: SQLiteRow) throws -> CollectionCloudSyncState {
        guard let deleted = try row.int64("ZDELETEDFLAG"),
              let editGeneration = try row.int64("ZEDITGENERATION"),
              let syncGeneration = try row.int64("ZSYNCGENERATION") else {
            throw CollectionCloudSyncError.cloudRecordInvalid
        }
        return CollectionCloudSyncState(
            deleted: deleted != 0,
            editGeneration: editGeneration,
            syncGeneration: syncGeneration,
            systemFieldsBytes: try row.int64("ZSYSTEMFIELDSBYTES") ?? 0
        )
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
