import Foundation
import SQLite3

enum CollectionWriteError: Error, Equatable {
    case collectionMissing
    case collectionDeletedOrUnknown
    case collectionIdentityUnavailable
    case collectionNotEditable
}

enum CollectionWriteScope {
    case collection
    case membership
}

struct CollectionWriteTarget: Equatable {
    let localPK: Int64
}

enum CollectionWriter {
    private static let membershipEditableSystemID = "Want_To_Read_Collection_ID"

    static func editableTarget(
        localPK: Int64,
        scope: CollectionWriteScope,
        on handle: OpaquePointer
    ) throws -> CollectionWriteTarget {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "SELECT Z_PK, ZCOLLECTIONID, ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK = ?",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CollectionWriteError.collectionMissing
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.collectionMissing
        }

        guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 2) == 0 else {
            throw CollectionWriteError.collectionDeletedOrUnknown
        }
        guard sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              let rawID = sqlite3_column_text(statement, 1) else {
            throw CollectionWriteError.collectionIdentityUnavailable
        }
        let collectionID = String(cString: rawID)

        if scope == .membership, collectionID == membershipEditableSystemID {
            return CollectionWriteTarget(localPK: localPK)
        }
        guard UUID(uuidString: collectionID) != nil else {
            throw CollectionWriteError.collectionNotEditable
        }
        return CollectionWriteTarget(localPK: localPK)
    }
}
