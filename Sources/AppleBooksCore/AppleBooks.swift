import Foundation

public enum StableIdentityError: Error, Equatable, Sendable {
    case ambiguousBookAssetID
    case ambiguousCollectionID
    case ambiguousAnnotationUUID
}

public enum PDFHighlightFacadeError: Error, Equatable, Sendable {
    case workerUnavailable
}

public final class AppleBooks {
    public static let defaultPDFWorkerTimeout: TimeInterval = PDFWorkerClient.defaultTimeout

    private let bookQueries: BookQueries
    private let collectionQueries: CollectionQueries
    private let annotationQueries: AnnotationQueries
    private let readingQueries: ReadingQueries
    private let collectionWriter: CollectionWriter
    private let annotationWriter: AnnotationWriter
    private let restoreCoordinator: MutationCoordinator
    private let libraryDatabase: URL
    private let libraryBackupRoot: URL
    private let pdfSourceResolver: PDFSourceResolver
    private let pdfWorkerClient: PDFWorkerClient?
    let configuration: AppleBooksConfiguration

    public convenience init(
        libraryDB: URL,
        annotationsDB: URL,
        configurationFile: URL? = nil,
        manageBooksApplication: Bool = true,
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws {
        let booksApp = manageBooksApplication ? BooksAppController.live : BooksAppController.detached
        let collectionCloudProjector = manageBooksApplication
            ? CollectionCloudProjector.live(libraryDatabase: libraryDB)
            : nil
        let collectionCloudSynchronizer = manageBooksApplication
            ? CollectionCloudSynchronizer.live(libraryDatabase: libraryDB, booksApp: booksApp)
            : nil
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: configurationFile,
            collectionWriter: CollectionWriter(
                database: libraryDB,
                booksApp: booksApp,
                cloudProjector: collectionCloudProjector,
                cloudSynchronizer: collectionCloudSynchronizer
            ),
            annotationWriter: AnnotationWriter(database: annotationsDB, booksApp: booksApp),
            restoreCoordinator: MutationCoordinator(database: libraryDB, booksApp: booksApp),
            pdfWorkerClient: pdfWorkerURL.map {
                PDFWorkerClient(workerURL: $0, timeout: pdfWorkerTimeout ?? PDFWorkerClient.defaultTimeout)
            }
        )
    }

    init(
        libraryDB: URL,
        annotationsDB: URL,
        configurationFile: URL?,
        collectionWriter: CollectionWriter,
        annotationWriter: AnnotationWriter? = nil,
        libraryBackupRoot: URL = SQLiteBackup.defaultRoot(),
        restoreCoordinator: MutationCoordinator? = nil,
        pdfSourceResolver: PDFSourceResolver = PDFSourceResolver(),
        pdfWorkerClient: PDFWorkerClient? = nil
    ) throws {
        let libraryConnection = try SQLiteConnection.readOnly(path: libraryDB.path)
        let annotationConnection = try SQLiteConnection.readOnly(path: annotationsDB.path)
        let configuration = try configurationFile.map(AppleBooksConfiguration.init(fileURL:))
            ?? AppleBooksConfiguration.loadDefault()

        let books = BookQueries(connection: libraryConnection)
        bookQueries = books
        collectionQueries = CollectionQueries(connection: libraryConnection)
        annotationQueries = AnnotationQueries(
            annotationConnection: annotationConnection,
            bookQueries: books,
            historicalAssets: configuration.historicalAssets
        )
        readingQueries = ReadingQueries(
            connection: libraryConnection,
            annotationConnection: annotationConnection
        )
        self.collectionWriter = collectionWriter
        self.annotationWriter = annotationWriter ?? AnnotationWriter(database: annotationsDB)
        self.restoreCoordinator = restoreCoordinator ?? MutationCoordinator(
            database: libraryDB,
            backupRoot: libraryBackupRoot
        )
        libraryDatabase = libraryDB
        self.libraryBackupRoot = libraryBackupRoot
        self.pdfSourceResolver = pdfSourceResolver
        self.pdfWorkerClient = pdfWorkerClient
        self.configuration = configuration
    }

    public func listLibraryBackups() throws -> [LibraryBackup] {
        try SQLiteBackup.list(source: libraryDatabase, backupRoot: libraryBackupRoot)
    }

    public func restoreLibraryBackup(handle: String) throws -> RestoreResult {
        try restoreCoordinator.restoreLibrary(handle: handle)
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

    public func books(inCollectionLocalPK localPK: Int64) throws -> [Book]? {
        guard let collection = try collectionQueries.getByLocalPK(localPK) else { return nil }
        return try collectionQueries.books(in: collection)
    }

    public func books(inCollectionID collectionID: String) throws -> [Book]? {
        guard let collection = try collectionQueries.getUniqueByCollectionID(collectionID) else { return nil }
        return try collectionQueries.books(in: collection)
    }

    public func createCollection(
        title: String,
        details: String? = nil,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try collectionWriter.createCollection(title: title, details: details, syncCloud: syncCloud)
    }

    public func renameCollection(localPK: Int64, newTitle: String) throws -> MutationResult {
        try collectionWriter.renameCollection(localPK: localPK, newTitle: newTitle)
    }

    public func renameCollection(collectionID: String, newTitle: String) throws -> MutationResult {
        try collectionWriter.renameCollection(collectionID: collectionID, newTitle: newTitle)
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

    public func addBook(bookLocalPK: Int64, toCollectionID collectionID: String) throws -> MutationResult {
        try collectionWriter.addBook(bookLocalPK: bookLocalPK, toCollectionID: collectionID)
    }

    public func addBook(assetID: String, toCollectionLocalPK collectionLocalPK: Int64) throws -> MutationResult {
        try collectionWriter.addBook(assetID: assetID, toCollectionLocalPK: collectionLocalPK)
    }

    public func removeBook(bookLocalPK: Int64, fromCollectionLocalPK collectionLocalPK: Int64) throws -> MutationResult {
        try collectionWriter.removeBook(bookLocalPK: bookLocalPK, fromCollectionLocalPK: collectionLocalPK)
    }

    public func removeBook(assetID: String, fromCollectionID collectionID: String) throws -> MutationResult {
        try collectionWriter.removeBook(assetID: assetID, fromCollectionID: collectionID)
    }

    public func removeBook(bookLocalPK: Int64, fromCollectionID collectionID: String) throws -> MutationResult {
        try collectionWriter.removeBook(bookLocalPK: bookLocalPK, fromCollectionID: collectionID)
    }

    public func removeBook(assetID: String, fromCollectionLocalPK collectionLocalPK: Int64) throws -> MutationResult {
        try collectionWriter.removeBook(assetID: assetID, fromCollectionLocalPK: collectionLocalPK)
    }

    public func listBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try bookQueries.list(limit: limit, offset: offset)
    }

    public func annotatedBooks() throws -> [BookOverview] {
        let counts = try userAnnotationCountsByAssetID()
        return try bookQueries.list().compactMap { book in
            guard let assetID = book.assetID,
                  let count = counts[assetID],
                  count > 0 else {
                return nil
            }
            return BookOverview(book: book, userAnnotationCount: count)
        }
    }

    public func bookOverview(localPK: Int64) throws -> BookOverview? {
        guard let book = try bookQueries.getByLocalPK(localPK) else { return nil }
        let counts = try userAnnotationCountsByAssetID()
        let count = book.assetID.flatMap { counts[$0] } ?? 0
        return BookOverview(book: book, userAnnotationCount: count)
    }

    public func bookOverview(assetID: String) throws -> BookOverview? {
        guard let book = try bookQueries.getUniqueByAssetID(assetID) else { return nil }
        let counts = try userAnnotationCountsByAssetID()
        return BookOverview(book: book, userAnnotationCount: counts[assetID] ?? 0)
    }

    public func libraryStats() throws -> LibraryStats {
        let books = try bookQueries.list()
        let finished = try readingQueries.finished()
        let inProgress = try readingQueries.inProgress()
        let unstarted = try readingQueries.unstarted()
        let annotations = try annotationQueries.list(scope: .user)

        var booksByAssetID: [String: [Book]] = [:]
        var bookByLocalPK: [Int64: Book] = [:]
        var orderByLocalPK: [Int64: Int] = [:]
        for (index, book) in books.enumerated() {
            bookByLocalPK[book.localPK] = book
            orderByLocalPK[book.localPK] = index
            if let assetID = book.assetID {
                booksByAssetID[assetID, default: []].append(book)
            }
        }

        var countsByLocalPK: [Int64: Int] = [:]
        var orphanCount = 0
        for enriched in annotations {
            guard let assetID = enriched.annotation.rawAssetID,
                  let matches = booksByAssetID[assetID],
                  matches.count == 1,
                  let book = matches.first else {
                orphanCount += 1
                continue
            }
            countsByLocalPK[book.localPK, default: 0] += 1
        }

        let topAnnotated = countsByLocalPK.compactMap { localPK, count -> BookOverview? in
            guard let book = bookByLocalPK[localPK] else { return nil }
            return BookOverview(book: book, userAnnotationCount: count)
        }.sorted { lhs, rhs in
            if lhs.userAnnotationCount != rhs.userAnnotationCount {
                return lhs.userAnnotationCount > rhs.userAnnotationCount
            }
            return (orderByLocalPK[lhs.book.localPK] ?? .max) < (orderByLocalPK[rhs.book.localPK] ?? .max)
        }.prefix(5)

        return LibraryStats(
            totalBooks: books.count,
            finishedBooks: finished.count,
            inProgressBooks: inProgress.count,
            unstartedBooks: unstarted.count,
            totalUserAnnotations: annotations.count,
            orphanUserAnnotations: orphanCount,
            topAnnotatedBooks: Array(topAnnotated)
        )
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

    public func pdfSources() throws -> [PDFSource] {
        pdfSourceResolver.resolve(pdfBooks: try bookQueries.pdfBooks())
    }

    public func pdfSource(forBookLocalPK localPK: Int64) throws -> PDFSource? {
        guard let book = try bookQueries.pdfBooks().first(where: { $0.localPK == localPK }) else { return nil }
        return pdfSourceResolver.resolve(book: book)
    }

    public func pdfSource(fileURL: URL) throws -> PDFSource? {
        pdfSourceResolver.resolve(fileURL: fileURL, pdfBooks: try bookQueries.pdfBooks())
    }

    public func pdfHighlights() throws -> PDFHighlightServiceResult {
        try pdfHighlightService().readHighlights()
    }

    public func pdfHighlights(source: PDFSource) throws -> PDFHighlightServiceResult {
        try pdfHighlightService().readHighlights(sources: [source])
    }

    private func pdfHighlightService() throws -> PDFHighlightService {
        guard let pdfWorkerClient else { throw PDFHighlightFacadeError.workerUnavailable }
        return PDFHighlightService(
            bookQueries: bookQueries,
            sourceResolver: pdfSourceResolver,
            workerClient: pdfWorkerClient
        )
    }

    public func exportBundle(options: ExportOptions) throws -> ExportBundle {
        let pdfService = pdfWorkerClient.map {
            PDFHighlightService(
                bookQueries: bookQueries,
                sourceResolver: pdfSourceResolver,
                workerClient: $0
            )
        }
        return try ExportService(
            annotationQueries: annotationQueries,
            bookQueries: bookQueries,
            configuration: configuration,
            pdfService: pdfService
        ).makeBundle(options: options)
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

    public func contentStatus(forBookLocalPK localPK: Int64) throws -> EPUBContentStatus? {
        guard let book = try bookQueries.getForContent(localPK) else { return nil }
        return EPUBContentInspector.status(book: book, configuration: configuration)
    }

    public func contentMetadata(forBookLocalPK localPK: Int64) throws -> EPUBMetadataInspection? {
        guard let book = try bookQueries.getForContent(localPK) else { return nil }
        return try EPUBContentInspector.metadata(book: book, configuration: configuration)
    }

    public func contentCover(forBookLocalPK localPK: Int64) throws -> EPUBCoverInspection? {
        guard let book = try bookQueries.getForContent(localPK) else { return nil }
        return try EPUBContentInspector.cover(book: book, configuration: configuration)
    }

    public func locate(rawCFI: String, forBookLocalPK localPK: Int64) throws -> EPUBLocationInspection? {
        guard let book = try bookQueries.getForContent(localPK) else { return nil }
        return try EPUBContentInspector.locate(rawCFI: rawCFI, book: book, configuration: configuration)
    }

    public func bookContent(forBookLocalPK localPK: Int64) throws -> BookContent {
        guard let book = try bookQueries.getForContent(localPK) else {
            throw ContentError.bookPathUnavailable
        }
        return try bookContent(for: book)
    }

    private func bookContent(for book: Book) throws -> BookContent {
        try BookContent(reader: EPUBSourceResolver.reader(for: book, configuration: configuration))
    }

    public func listAnnotations(
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.list(scope: scope, limit: limit, offset: offset)
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

    public func annotation(localPK: Int64, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        try annotationQueries.getByLocalPK(localPK, scope: scope)
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

    public func annotations(
        bookAssetID: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.byAssetID(bookAssetID, scope: scope, limit: limit, offset: offset)
    }

    public func annotations(
        bookLocalPK: Int64,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try bookQueries.getByLocalPK(bookLocalPK), let assetID = book.assetID else { return [] }
        return try annotationQueries.byAssetID(assetID, scope: scope, limit: limit, offset: offset)
    }

    public func annotationsInReadingOrder(
        bookLocalPK: Int64,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try bookQueries.getByLocalPK(bookLocalPK) else { return [] }
        return try annotationsInReadingOrder(book: book, limit: limit, offset: offset)
    }

    public func annotationsInReadingOrder(
        bookAssetID assetID: String,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try bookQueries.getUniqueByAssetID(assetID) else { return [] }
        return try annotationsInReadingOrder(book: book, limit: limit, offset: offset)
    }

    private func annotationsInReadingOrder(
        book: Book,
        limit: Int?,
        offset: Int
    ) throws -> [EnrichedAnnotation] {
        guard let assetID = book.assetID else { return [] }
        let annotations = try annotationQueries.byAssetID(assetID, scope: .user)
        guard annotations.isEmpty == false else { return [] }

        var chapterOrder: [String: Int] = [:]
        do {
            for chapter in try bookContent(for: book).listChapters() {
                chapterOrder[chapter.id] = min(chapterOrder[chapter.id] ?? .max, chapter.order)
            }
        } catch {
            chapterOrder.removeAll(keepingCapacity: false)
        }

        let sorted = annotations.sorted { lhs, rhs in
            let lhsOrder = lhs.annotation.location?.chapterID.flatMap { chapterOrder[$0] } ?? .max
            let rhsOrder = rhs.annotation.location?.chapterID.flatMap { chapterOrder[$0] } ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }

            switch (lhs.annotation.createdAt, rhs.annotation.createdAt) {
            case (nil, nil):
                return lhs.annotation.localPK < rhs.annotation.localPK
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.annotation.localPK < rhs.annotation.localPK
            }
        }
        let paged = sorted.dropFirst(offset)
        guard let limit else { return Array(paged) }
        return Array(paged.prefix(limit))
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
        guard book.path != nil else {
            throw AnnotationContextError.contentPathUnavailable
        }
        guard let chapterID = annotation.location?.chapterID else {
            throw AnnotationContextError.chapterUnavailable
        }

        let content = try bookContent(for: book)
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
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchHighlightedText(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingNote text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchNote(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try annotationQueries.searchText(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func recentlyCreatedAnnotations(limit: Int? = 10, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try annotationQueries.recentlyCreated(limit: limit, offset: offset)
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

    private func userAnnotationCountsByAssetID() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for enriched in try annotationQueries.list(scope: .user) {
            if let assetID = enriched.annotation.rawAssetID {
                counts[assetID, default: 0] += 1
            }
        }
        return counts
    }

    public func currentReadingChapter(forBookLocalPK localPK: Int64) throws -> Chapter? {
        guard let bookmark = try currentReadingLocation(forBookLocalPK: localPK),
              let chapterID = bookmark.location?.chapterID else {
            return nil
        }
        let content = try bookContent(forBookLocalPK: localPK)
        return try CurrentReadingChapter.resolve(chapterID: chapterID, in: content)
    }

    public func currentReadingPosition(forBookLocalPK localPK: Int64) throws -> ReadingPosition? {
        if let chapter = try currentReadingChapter(forBookLocalPK: localPK) {
            let totalChapters: Int?
            do {
                totalChapters = try bookContent(forBookLocalPK: localPK).listChapters().count
            } catch {
                totalChapters = nil
            }
            return ReadingPosition(
                chapterID: chapter.id,
                title: chapter.title,
                order: chapter.order,
                totalChapters: totalChapters,
                source: .bookmarkToc
            )
        }

        let bookmark = try currentReadingLocation(forBookLocalPK: localPK)
        if let chapterID = bookmark?.location?.chapterID {
            return ReadingPosition(
                chapterID: chapterID,
                title: nil,
                order: nil,
                totalChapters: nil,
                source: .bookmarkHint
            )
        }

        guard let book = try bookQueries.getForCurrentReadingLocation(localPK),
              let assetID = book.assetID else {
            return nil
        }
        let candidate = try annotationQueries.byAssetID(assetID, scope: .user)
            .filter { $0.annotation.location?.chapterID != nil }
            .sorted { lhs, rhs in
                switch (lhs.annotation.createdAt, rhs.annotation.createdAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.annotation.localPK > rhs.annotation.localPK
                }
            }
            .first
        guard let candidate,
              let chapterID = candidate.annotation.location?.chapterID else {
            return nil
        }

        let chapters = try bookContent(forBookLocalPK: localPK).listChapters()
        let title = chapters.first(where: { $0.id == chapterID })?.title
        return ReadingPosition(
            chapterID: chapterID,
            title: title,
            order: nil,
            totalChapters: nil,
            source: .recentAnnotationInference
        )
    }
}
