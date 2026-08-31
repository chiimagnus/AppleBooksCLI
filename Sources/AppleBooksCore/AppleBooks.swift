import Foundation

public enum StableIdentityError: Error, Equatable, Sendable {
    case ambiguousBookAssetID
    case ambiguousCollectionID
    case ambiguousAnnotationUUID
}

public final class AppleBooks {
    private let bookQueries: BookQueries
    private let collectionQueries: CollectionQueries
    private let annotationQueries: AnnotationQueries
    private let readingQueries: ReadingQueries
    private let collectionWriter: CollectionWriter
    private let annotationWriter: AnnotationWriter

    public convenience init(
        libraryDB: URL,
        annotationsDB: URL,
        historicalConfig: URL? = nil
    ) throws {
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            historicalConfig: historicalConfig,
            collectionWriter: CollectionWriter(database: libraryDB),
            annotationWriter: AnnotationWriter(database: annotationsDB)
        )
    }

    init(
        libraryDB: URL,
        annotationsDB: URL,
        historicalConfig: URL?,
        collectionWriter: CollectionWriter,
        annotationWriter: AnnotationWriter? = nil
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
        self.collectionWriter = collectionWriter
        self.annotationWriter = annotationWriter ?? AnnotationWriter(database: annotationsDB)
    }

    // Stable deterministic order + validated pagination.
    public func listCollections(limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try collectionQueries.list(limit: limit, offset: offset)
    }

    // Missing or deleted collections return nil.
    public func collection(localPK: Int64) throws -> Collection? {
        try collectionQueries.getByLocalPK(localPK)
    }

    public func collection(collectionID: String) throws -> Collection? {
        try collectionQueries.getUniqueByCollectionID(collectionID)
    }

    // Title is a search field, never collection identity.
    public func collections(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try collectionQueries.searchTitle(text, limit: limit, offset: offset)
    }

    public func createCollection(title: String, details: String? = nil) throws -> MutationResult {
        try collectionWriter.createCollection(title: title, details: details)
    }

    public func renameCollection(localPK: Int64, newTitle: String) throws -> MutationResult {
        try collectionWriter.renameCollection(localPK: localPK, newTitle: newTitle)
    }

    public func deleteCollection(localPK: Int64) throws -> MutationResult {
        try collectionWriter.deleteCollection(localPK: localPK)
    }

    public func deleteCollection(collectionID: String) throws -> MutationResult {
        try collectionWriter.deleteCollection(collectionID: collectionID)
    }

    public func addBook(bookLocalPK: Int64, toCollectionLocalPK collectionLocalPK: Int64) throws -> MutationResult {
        try collectionWriter.addBook(bookLocalPK: bookLocalPK, toCollectionLocalPK: collectionLocalPK)
    }

    public func addBook(assetID: String, toCollectionID collectionID: String) throws -> MutationResult {
        try collectionWriter.addBook(assetID: assetID, toCollectionID: collectionID)
    }

    public func removeBook(bookLocalPK: Int64, fromCollectionLocalPK collectionLocalPK: Int64) throws -> MutationResult {
        try collectionWriter.removeBook(bookLocalPK: bookLocalPK, fromCollectionLocalPK: collectionLocalPK)
    }

    public func removeBook(assetID: String, fromCollectionID collectionID: String) throws -> MutationResult {
        try collectionWriter.removeBook(assetID: assetID, fromCollectionID: collectionID)
    }

    public func listBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.list(limit: limit, offset: offset)
    }

    public func bookPage(limit: Int? = nil, offset: Int = 0) throws -> Page<Book> {
        try bookQueries.page(limit: limit, offset: offset)
    }

    public func book(localPK: Int64) throws -> Book? {
        try bookQueries.getByLocalPK(localPK)
    }

    public func book(assetID: String) throws -> Book? {
        try bookQueries.getUniqueByAssetID(assetID)
    }

    public func books(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.searchTitle(text, limit: limit, offset: offset)
    }

    public func books(matchingGenre text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.searchGenre(text, limit: limit, offset: offset)
    }

    public func books(matching text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.search(text, limit: limit, offset: offset)
    }

    public func bookContent(forBookLocalPK localPK: Int64) throws -> BookContent {
        guard let book = try bookQueries.getForContent(localPK), let path = book.path else {
            throw ContentError.bookPathUnavailable
        }
        return try BookContent(root: URL(fileURLWithPath: path))
    }

    public func listAnnotations(limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.list(limit: limit, offset: offset)
    }

    public func annotationPage(
        scope: AnnotationScope = .activeRaw,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> Page<EnrichedAnnotation> {
        try annotationQueries.page(scope: scope, limit: limit, offset: offset)
    }

    public func annotationPage(
        colorName: String,
        scope: AnnotationScope = .activeRaw,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> Page<EnrichedAnnotation> {
        try annotationQueries.page(colorName: colorName, scope: scope, limit: limit, offset: offset)
    }

    public func annotation(localPK: Int64) throws -> EnrichedAnnotation? {
        try annotationQueries.getByLocalPK(localPK)
    }

    public func updateAnnotationNote(localPK: Int64, note: String) throws -> MutationResult {
        try annotationWriter.updateNote(localPK: localPK, note: note)
    }

    public func updateAnnotationNote(uuid: String, note: String) throws -> MutationResult {
        try annotationWriter.updateNote(uuid: uuid, note: note)
    }

    public func deleteAnnotation(localPK: Int64) throws -> MutationResult {
        try annotationWriter.delete(localPK: localPK)
    }

    public func deleteAnnotation(uuid: String) throws -> MutationResult {
        try annotationWriter.delete(uuid: uuid)
    }

    public func annotation(uuid: String, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        try annotationQueries.getUniqueByUUID(uuid, scope: scope)
    }

    public func annotations(bookAssetID: String, scope: AnnotationScope = .user) throws -> [EnrichedAnnotation] {
        try annotationQueries.byAssetID(bookAssetID, scope: scope)
    }

    public func annotations(bookLocalPK: Int64, scope: AnnotationScope = .user) throws -> [EnrichedAnnotation] {
        guard let book = try bookQueries.getByLocalPK(bookLocalPK), let assetID = book.assetID else { return [] }
        return try annotationQueries.byAssetID(assetID, scope: scope)
    }

    public func annotationContext(
        localPK: Int64,
        charsBefore: Int = 300,
        charsAfter: Int = 300
    ) throws -> AnnotationContext {
        guard charsBefore >= 0, charsAfter >= 0 else {
            throw AnnotationContextError.invalidWindow
        }
        guard let enriched = try annotationQueries.getByLocalPK(localPK) else {
            throw AnnotationContextError.annotationUnavailable
        }
        let annotation = enriched.annotation
        guard let assetID = annotation.rawAssetID else {
            throw AnnotationContextError.assetIdentityUnavailable
        }
        let books = try bookQueries.getByAssetID(assetID)
        guard books.isEmpty == false else {
            throw AnnotationContextError.currentBookUnavailable
        }
        guard books.count == 1, let book = books.first else {
            throw AnnotationContextError.currentBookAmbiguous
        }
        guard let path = book.path else {
            throw AnnotationContextError.contentPathUnavailable
        }
        guard let chapterID = annotation.location?.chapterID else {
            throw AnnotationContextError.chapterUnavailable
        }

        let content = try BookContent(root: URL(fileURLWithPath: path))
        let chapterText: String
        do {
            chapterText = try content.getChapter(chapterID)
        } catch BookContentError.chapterNotFound {
            throw AnnotationContextError.chapterUnavailable
        }
        let selected = annotation.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let representative = annotation.representativeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let anchor = selected.isEmpty ? representative : selected
        guard anchor.isEmpty == false else {
            throw AnnotationContextError.anchorUnavailable
        }
        return try AnnotationContextMatcher.match(
            chapterText: chapterText,
            anchor: anchor,
            charsBefore: charsBefore,
            charsAfter: charsAfter
        )
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

    public func annotations(matchingText text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchText(text, limit: limit, offset: offset)
    }

    public func recentlyModifiedAnnotations() throws -> [EnrichedAnnotation] {
        try annotationQueries.recentlyModified()
    }

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

    public func currentReadingLocation(forBookLocalPK localPK: Int64) throws -> Annotation? {
        guard let book = try bookQueries.getForCurrentReadingLocation(localPK),
              let assetID = book.assetID else {
            return nil
        }
        return try readingQueries.currentPosition(rawAssetID: assetID)
    }

    public func currentReadingChapter(forBookLocalPK localPK: Int64) throws -> Chapter? {
        guard let bookmark = try currentReadingLocation(forBookLocalPK: localPK),
              let chapterID = bookmark.location?.chapterID else {
            return nil
        }
        let content = try bookContent(forBookLocalPK: localPK)
        return try CurrentReadingChapter.resolve(chapterID: chapterID, in: content)
    }
}
