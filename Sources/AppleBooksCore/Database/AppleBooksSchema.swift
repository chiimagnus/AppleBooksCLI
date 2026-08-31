import Foundation

public enum AppleBooksTable: String, Equatable, Sendable {
    case books = "ZBKLIBRARYASSET"
    case collections = "ZBKCOLLECTION"
    case collectionMembers = "ZBKCOLLECTIONMEMBER"
    case annotations = "ZAEANNOTATION"
}

public enum SchemaCompatibilityError: Error, Equatable, Sendable {
    case missingTable(AppleBooksTable)
    case missingRequiredColumns(table: AppleBooksTable, columns: [String])
}

struct SchemaAvailability: Equatable {
    let table: AppleBooksTable
    let columns: Set<String>

    func contains(_ column: String) -> Bool {
        columns.contains(column)
    }
}

enum AppleBooksSchema {
    enum Book {
        static let localPK = "Z_PK"
        static let assetID = "ZASSETID"
        static let title = "ZTITLE"
        static let author = "ZAUTHOR"
        static let description = "ZBOOKDESCRIPTION"
        static let genre = "ZGENRE"
        static let contentType = "ZCONTENTTYPE"
        static let pageCount = "ZPAGECOUNT"
        static let path = "ZPATH"
        static let fileSize = "ZFILESIZE"
        static let isFinished = "ZISFINISHED"
        static let readingProgress = "ZREADINGPROGRESS"
        static let duration = "ZDURATION"
        static let creationDate = "ZCREATIONDATE"
        static let finishedDate = "ZDATEFINISHED"
        static let lastOpenDate = "ZLASTOPENDATE"
        static let purchaseDate = "ZPURCHASEDATE"
        static let isExplicit = "ZISEXPLICIT"
        static let isLocked = "ZISLOCKED"
        static let isEphemeral = "ZISEPHEMERAL"
        static let isHidden = "ZISHIDDEN"
        static let isSample = "ZISSAMPLE"
        static let isStoreAudiobook = "ZISSTOREAUDIOBOOK"
        static let rating = "ZRATING"

        static let allProjection = [
            assetID, title, author, description, genre, contentType, pageCount, path, fileSize,
            isFinished, readingProgress, duration, creationDate, finishedDate, lastOpenDate,
            purchaseDate, isExplicit, isLocked, isEphemeral, isHidden, isSample,
            isStoreAudiobook, rating,
        ]
    }

    enum Collection {
        static let localPK = "Z_PK"
        static let collectionID = "ZCOLLECTIONID"
        static let title = "ZTITLE"
        static let details = "ZDETAILS"
        static let isDeleted = "ZDELETEDFLAG"
        static let isHidden = "ZHIDDEN"
        static let allProjection = [collectionID, title, details, isDeleted, isHidden]
    }

    enum Member {
        static let localPK = "Z_PK"
        static let collection = "ZCOLLECTION"
        static let assetID = "ZASSETID"
        static let sortKey = "ZSORTKEY"
    }

    enum Annotation {
        static let localPK = "Z_PK"
        static let uuid = "ZANNOTATIONUUID"
        static let assetID = "ZANNOTATIONASSETID"
        static let isDeleted = "ZANNOTATIONDELETED"
        static let isUnderline = "ZANNOTATIONISUNDERLINE"
        static let style = "ZANNOTATIONSTYLE"
        static let type = "ZANNOTATIONTYPE"
        static let creationDate = "ZANNOTATIONCREATIONDATE"
        static let modificationDate = "ZANNOTATIONMODIFICATIONDATE"
        static let selectedText = "ZANNOTATIONSELECTEDTEXT"
        static let representativeText = "ZANNOTATIONREPRESENTATIVETEXT"
        static let note = "ZANNOTATIONNOTE"
        static let location = "ZANNOTATIONLOCATION"
        static let physicalLocation = "ZPLABSOLUTEPHYSICALLOCATION"
        static let rangeStart = "ZPLLOCATIONRANGESTART"
        static let rangeEnd = "ZPLLOCATIONRANGEEND"
        static let chapterHint = "ZFUTUREPROOFING5"

        static let allProjection = [
            uuid, assetID, isDeleted, isUnderline, style, type, creationDate, modificationDate,
            selectedText, representativeText, note, location, physicalLocation, rangeStart,
            rangeEnd, chapterHint,
        ]
    }

    static func inspect(_ capability: SchemaCapability, on connection: SQLiteConnection) throws -> SchemaAvailability {
        let statement = try connection.prepare("SELECT name FROM pragma_table_info(?) ORDER BY cid")
        try statement.bind(capability.table.rawValue, at: 1)
        var columns = Set<String>()
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            if let name = try row.text("name") {
                columns.insert(name)
            }
        }
        guard columns.isEmpty == false else {
            throw SchemaCompatibilityError.missingTable(capability.table)
        }
        let missing = capability.required.filter { columns.contains($0) == false }.sorted()
        guard missing.isEmpty else {
            throw SchemaCompatibilityError.missingRequiredColumns(table: capability.table, columns: missing)
        }
        return SchemaAvailability(table: capability.table, columns: columns)
    }
}

enum SchemaCapability: CaseIterable {
    case bookBase
    case bookTitleSearch
    case bookGenreSearch
    case bookAssetLookup
    case bookCurrentReadingAssetLookup
    case bookContentPathLookup
    case readingFinished
    case readingInProgress
    case readingUnstarted
    case readingRecentlyRead
    case collectionBase
    case collectionTitleSearch
    case collectionMembers
    case collectionMemberBooks
    case annotationUserBase
    case annotationByUUID
    case annotationByAssetID
    case annotationByStyle
    case annotationByCreationDate
    case annotationHighlightedText
    case annotationNote
    case annotationFullText
    case currentPosition

    var table: AppleBooksTable {
        switch self {
        case .bookBase, .bookTitleSearch, .bookGenreSearch, .bookAssetLookup,
             .bookCurrentReadingAssetLookup, .bookContentPathLookup, .readingFinished, .readingInProgress,
             .readingUnstarted, .readingRecentlyRead, .collectionMemberBooks:
            .books
        case .collectionBase, .collectionTitleSearch:
            .collections
        case .collectionMembers:
            .collectionMembers
        case .annotationUserBase, .annotationByUUID, .annotationByAssetID, .annotationByStyle,
             .annotationByCreationDate, .annotationHighlightedText, .annotationNote,
             .annotationFullText, .currentPosition:
            .annotations
        }
    }

    var required: [String] {
        switch self {
        case .bookBase:
            [AppleBooksSchema.Book.localPK]
        case .bookTitleSearch:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.title]
        case .bookGenreSearch:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.genre]
        case .bookAssetLookup, .bookCurrentReadingAssetLookup:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.assetID]
        case .bookContentPathLookup:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.path]
        case .readingFinished:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.isFinished]
        case .readingInProgress, .readingUnstarted:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.isFinished, AppleBooksSchema.Book.readingProgress]
        case .readingRecentlyRead:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.lastOpenDate]
        case .collectionBase:
            [AppleBooksSchema.Collection.localPK, AppleBooksSchema.Collection.isDeleted]
        case .collectionTitleSearch:
            [AppleBooksSchema.Collection.localPK, AppleBooksSchema.Collection.isDeleted, AppleBooksSchema.Collection.title]
        case .collectionMembers:
            [AppleBooksSchema.Member.localPK, AppleBooksSchema.Member.collection, AppleBooksSchema.Member.assetID]
        case .collectionMemberBooks:
            [AppleBooksSchema.Book.localPK, AppleBooksSchema.Book.assetID]
        case .annotationUserBase:
            annotationUserRequired
        case .annotationByUUID:
            annotationUserRequired + [AppleBooksSchema.Annotation.uuid]
        case .annotationByAssetID:
            annotationUserRequired + [AppleBooksSchema.Annotation.assetID]
        case .annotationByStyle:
            annotationUserRequired + [AppleBooksSchema.Annotation.style]
        case .annotationByCreationDate:
            annotationUserRequired + [AppleBooksSchema.Annotation.creationDate]
        case .annotationHighlightedText:
            annotationUserRequired + [AppleBooksSchema.Annotation.selectedText]
        case .annotationNote:
            annotationUserRequired + [AppleBooksSchema.Annotation.note]
        case .annotationFullText:
            annotationUserRequired + [
                AppleBooksSchema.Annotation.selectedText,
                AppleBooksSchema.Annotation.representativeText,
                AppleBooksSchema.Annotation.note,
            ]
        case .currentPosition:
            [
                AppleBooksSchema.Annotation.localPK,
                AppleBooksSchema.Annotation.isDeleted,
                AppleBooksSchema.Annotation.type,
                AppleBooksSchema.Annotation.assetID,
            ]
        }
    }

    var optional: [String] {
        switch table {
        case .books:
            AppleBooksSchema.Book.allProjection.filter { required.contains($0) == false }
        case .collections:
            AppleBooksSchema.Collection.allProjection.filter { required.contains($0) == false }
        case .collectionMembers:
            [AppleBooksSchema.Member.sortKey]
        case .annotations:
            AppleBooksSchema.Annotation.allProjection.filter { required.contains($0) == false }
        }
    }

    private var annotationUserRequired: [String] {
        [
            AppleBooksSchema.Annotation.localPK,
            AppleBooksSchema.Annotation.isDeleted,
            AppleBooksSchema.Annotation.type,
        ]
    }
}
