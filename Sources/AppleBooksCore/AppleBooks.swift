import Foundation

public final class AppleBooks {
    private let bookQueries: BookQueries
    private let collectionQueries: CollectionQueries
    private let annotationQueries: AnnotationQueries
    private let readingQueries: ReadingQueries

    public init(
        libraryDB: URL,
        annotationsDB: URL,
        historicalConfig: URL? = nil
    ) throws {
        let libraryConnection = try SQLiteConnection.readOnly(path: libraryDB.path)
        let annotationConnection = try SQLiteConnection.readOnly(path: annotationsDB.path)
        let historicalAssets: HistoricalAssetMapping
        if let historicalConfig {
            historicalAssets = try HistoricalAssetMapping(fileURL: historicalConfig)
        } else {
            historicalAssets = try HistoricalAssetMapping.loadDefault()
        }

        let books = BookQueries(connection: libraryConnection)
        bookQueries = books
        collectionQueries = CollectionQueries(connection: libraryConnection)
        annotationQueries = AnnotationQueries(
            annotationConnection: annotationConnection,
            bookQueries: books,
            historicalAssets: historicalAssets
        )
        readingQueries = ReadingQueries(
            connection: libraryConnection,
            annotationConnection: annotationConnection
        )
    }

    // Stable deterministic order + validated pagination.
    public func listCollections(limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try collectionQueries.list(limit: limit, offset: offset)
    }

    // Missing or deleted collections return nil.
    public func collection(localPK: Int64) throws -> Collection? {
        try collectionQueries.getByLocalPK(localPK)
    }

    // Title is a search field, never collection identity.
    public func collections(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try collectionQueries.searchTitle(text, limit: limit, offset: offset)
    }

    public func listBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.list(limit: limit, offset: offset)
    }

    public func book(localPK: Int64) throws -> Book? {
        try bookQueries.getByLocalPK(localPK)
    }

    public func books(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.searchTitle(text, limit: limit, offset: offset)
    }

    public func books(matchingGenre text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.searchGenre(text, limit: limit, offset: offset)
    }

    public func bookContent(forBookLocalPK localPK: Int64) throws -> BookContent {
        guard let book = try bookQueries.getForContent(localPK), let path = book.path else {
            throw ContentError.bookPathUnavailable
        }
        return try BookContent(root: URL(fileURLWithPath: path))
    }

    // Upstream list_annotations, strengthened to deleted=0 AND type!=3.
    public func listAnnotations(limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.list(limit: limit, offset: offset)
    }

    public func annotation(localPK: Int64) throws -> EnrichedAnnotation? {
        try annotationQueries.getByLocalPK(localPK)
    }

    public func annotations(colorName: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.byColorName(colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingHighlightedText text: String,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchHighlightedText(text, limit: limit, offset: offset)
    }

    public func annotations(matchingNote text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchNote(text, limit: limit, offset: offset)
    }

    // Upstream search_annotation_by_text; grouped OR executes inside SQL before limit/offset.
    public func annotations(matchingText text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchText(text, limit: limit, offset: offset)
    }

    // Upstream get_annotations_by_date_range, deliberately half-open [lower, upper).
    public func annotations(
        createdAtOrAfter lowerInclusive: Date? = nil,
        beforeExclusive upperExclusive: Date? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.created(
            lowerInclusive: lowerInclusive,
            upperExclusive: upperExclusive,
            limit: limit,
            offset: offset
        )
    }

    public func booksInProgress(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try readingQueries.inProgress(limit: limit, offset: offset)
    }

    public func finishedBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try readingQueries.finished(limit: limit, offset: offset)
    }

    public func unstartedBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try readingQueries.unstarted(limit: limit, offset: offset)
    }

    public func recentlyReadBooks(limit: Int = 10, offset: Int = 0) throws -> [Book] {
        try readingQueries.recentlyRead(limit: limit, offset: offset)
    }

    // Upstream get_current_reading_location: public input is Book localPK; raw assetId remains internal.
    public func currentReadingLocation(forBookLocalPK localPK: Int64) throws -> Annotation? {
        guard let book = try bookQueries.getForCurrentReadingLocation(localPK),
              let assetID = book.assetID else {
            return nil
        }
        return try readingQueries.currentPosition(rawAssetID: assetID)
    }
}
