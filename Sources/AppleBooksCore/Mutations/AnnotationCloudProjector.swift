import AppleBooksCloudBridge
import Foundation

struct AnnotationCloudProjectionInput: Equatable {
    let localPK: Int64
}

enum AnnotationCloudProjectionError: Error, Equatable {
    case identityUnavailable
    case bridgeRejected(Int32)
}

struct AnnotationCloudIdentity: Equatable {
    let assetID: String
    let uuid: String
}

struct AnnotationCloudProjector {
    typealias BackupAction = (URL, URL) throws -> Void
    typealias BridgeAction = (URL, URL, URL, AnnotationCloudIdentity) -> Int32

    private let projectAction: (AnnotationCloudProjectionInput) throws -> Void

    init(projectAction: @escaping (AnnotationCloudProjectionInput) throws -> Void) {
        self.projectAction = projectAction
    }

    func project(_ input: AnnotationCloudProjectionInput) throws {
        try projectAction(input)
    }

    static func live(
        annotationsDatabase: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = SQLiteBackup.defaultRoot().appendingPathComponent("cloud-annotations", isDirectory: true),
        backupAction: @escaping BackupAction = { source, root in
            _ = try SQLiteBackup.create(source: source, backupRoot: root)
        },
        bridgeAction: @escaping BridgeAction = liveBridgeAction
    ) -> AnnotationCloudProjector? {
        guard let location = AnnotationCloudStoreLocation.live(
            annotationsDatabase: annotationsDatabase,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }
        return AnnotationCloudProjector { input in
            let identity = try identity(annotationsDatabase: annotationsDatabase, localPK: input.localPK)
            try backupAction(location.database, backupRoot)
            let status = bridgeAction(location.root, location.database, annotationsDatabase, identity)
            guard status == 0 else { throw AnnotationCloudProjectionError.bridgeRejected(status) }
        }
    }

    static func identity(annotationsDatabase: URL, localPK: Int64) throws -> AnnotationCloudIdentity {
        let connection = try SQLiteConnection.readOnly(path: annotationsDatabase.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("""
            SELECT ZANNOTATIONASSETID, ZANNOTATIONUUID
            FROM ZAEANNOTATION
            WHERE Z_PK=?
            ORDER BY rowid
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { throw AnnotationCloudProjectionError.identityUnavailable }
        let row = try SQLiteRow(statement: statement)
        guard let assetID = try row.text("ZANNOTATIONASSETID"), assetID.isEmpty == false,
              let uuid = try row.text("ZANNOTATIONUUID"), uuid.isEmpty == false,
              try statement.step() == false else {
            throw AnnotationCloudProjectionError.identityUnavailable
        }
        return AnnotationCloudIdentity(assetID: assetID, uuid: uuid)
    }

    private static func liveBridgeAction(
        root: URL,
        database: URL,
        annotationsDatabase: URL,
        identity: AnnotationCloudIdentity
    ) -> Int32 {
        root.path.withCString { rootPath in
            database.path.withCString { databasePath in
                annotationsDatabase.path.withCString { annotationsPath in
                    identity.assetID.withCString { assetID in
                        identity.uuid.withCString { uuid in
                            ABProjectAnnotationState(rootPath, databasePath, annotationsPath, assetID, uuid)
                        }
                    }
                }
            }
        }
    }
}
