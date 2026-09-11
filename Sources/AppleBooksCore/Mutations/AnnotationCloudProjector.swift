import AppleBooksCloudBridge
import Foundation

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

    private let projectAction: (Int64) throws -> Void

    init(projectAction: @escaping (Int64) throws -> Void) {
        self.projectAction = projectAction
    }

    func project(localPK: Int64) throws {
        try projectAction(localPK)
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
        return AnnotationCloudProjector { localPK in
            let identity = try identity(annotationsDatabase: annotationsDatabase, localPK: localPK)
            try backupAction(location.database, backupRoot)
            let status = bridgeAction(location.root, location.database, annotationsDatabase, identity)
            guard status == 0 else { throw AnnotationCloudProjectionError.bridgeRejected(status) }
        }
    }

    static func identity(annotationsDatabase: URL, localPK: Int64) throws -> AnnotationCloudIdentity {
        let connection = try SQLiteConnection.readOnly(path: annotationsDatabase.path)
        defer { try? connection.close() }
        let assetProjection = SQLiteTextProjection.exact(
            "ZANNOTATIONASSETID",
            alias: "cloudAssetID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        )
        let uuidProjection = SQLiteTextProjection.exact(
            "ZANNOTATIONUUID",
            alias: "cloudUUID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        )
        let statement = try connection.prepare("""
            SELECT \((assetProjection + uuidProjection).joined(separator: ", "))
            FROM ZAEANNOTATION
            WHERE Z_PK=?
            ORDER BY rowid
            LIMIT 2
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { throw AnnotationCloudProjectionError.identityUnavailable }
        let row = try SQLiteRow(statement: statement)
        let assetID: String
        let uuid: String
        switch try SQLiteTextProjection.decodeExact(
            row,
            alias: "cloudAssetID",
            column: "ZANNOTATIONASSETID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        ) {
        case let .value(value) where value.isEmpty == false: assetID = value
        case .value, .null, .oversized: throw AnnotationCloudProjectionError.identityUnavailable
        }
        switch try SQLiteTextProjection.decodeExact(
            row,
            alias: "cloudUUID",
            column: "ZANNOTATIONUUID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        ) {
        case let .value(value) where value.isEmpty == false: uuid = value
        case .value, .null, .oversized: throw AnnotationCloudProjectionError.identityUnavailable
        }
        guard try statement.step() == false else {
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
                    withCloudBridgeUTF8Bytes(identity.assetID) { assetID, assetIDLength in
                        withCloudBridgeUTF8Bytes(identity.uuid) { uuid, uuidLength in
                            ABProjectAnnotationState(
                                rootPath,
                                databasePath,
                                annotationsPath,
                                assetID,
                                assetIDLength,
                                uuid,
                                uuidLength
                            )
                        }
                    }
                }
            }
        }
    }
}
