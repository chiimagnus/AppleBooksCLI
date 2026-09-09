import Foundation

public enum StableIdentityError: Error, Equatable, Sendable {
    case ambiguousBookAssetID
    case ambiguousCollectionID
    case ambiguousAnnotationUUID
}

public enum PDFHighlightFacadeError: Error, Equatable, Sendable {
    case workerUnavailable
}

public enum AppleBooksCloudSyncError: Error, Equatable, Sendable {
    case unavailable
    case acknowledgementFailed
}

public struct CloudSyncSummary: Equatable, Sendable {
    public let collectionPendingBefore: Int
    public let annotationPendingBefore: Int

    public init(collectionPendingBefore: Int, annotationPendingBefore: Int) {
        self.collectionPendingBefore = collectionPendingBefore
        self.annotationPendingBefore = annotationPendingBefore
    }
}

public final class AppleBooks {
    public static let defaultPDFWorkerTimeout: TimeInterval = PDFWorkerClient.defaultTimeout

    private let bookQueries: BookQueries?
    private let collectionQueries: CollectionQueries?
    private let annotationQueries: AnnotationQueries?
    private let readingQueries: ReadingQueries?
    private let annotationConnection: SQLiteConnection?
    private let collectionWriter: CollectionWriter?
    private let annotationWriter: AnnotationWriter?
    private let restoreCoordinator: MutationCoordinator?
    private let libraryDatabase: URL?
    private let annotationsDatabase: URL?
    private let libraryBackupRoot: URL
    private let pdfSourceResolver: PDFSourceResolver
    private let pdfWorkerClient: PDFWorkerClient?
    private let dependencies: AppleBooksDependencies
    let configuration: AppleBooksConfiguration

    public convenience init(
        libraryDB: URL,
        annotationsDB: URL,
        configurationFile: URL? = nil,
        manageBooksApplication: Bool = true,
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws {
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: configurationFile,
            manageCollectionBooksApplication: manageBooksApplication,
            manageAnnotationBooksApplication: manageBooksApplication,
            pdfWorkerURL: pdfWorkerURL,
            pdfWorkerTimeout: pdfWorkerTimeout
        )
    }

    public convenience init(
        libraryDB: URL,
        annotationsDB: URL,
        configurationFile: URL? = nil,
        manageCollectionBooksApplication: Bool,
        manageAnnotationBooksApplication: Bool,
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws {
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: configurationFile,
            dependencies: .full,
            manageCollectionBooksApplication: manageCollectionBooksApplication,
            manageAnnotationBooksApplication: manageAnnotationBooksApplication,
            libraryBackupRoot: SQLiteBackup.defaultRoot(),
            collectionWriter: nil,
            annotationWriter: nil,
            restoreCoordinator: nil,
            pdfSourceResolver: PDFSourceResolver(),
            pdfWorkerClient: pdfWorkerURL.map {
                PDFWorkerClient(workerURL: $0, timeout: pdfWorkerTimeout ?? PDFWorkerClient.defaultTimeout)
            }
        )
    }

    convenience init(
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
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: configurationFile,
            dependencies: .full,
            manageCollectionBooksApplication: false,
            manageAnnotationBooksApplication: false,
            libraryBackupRoot: libraryBackupRoot,
            collectionWriter: collectionWriter,
            annotationWriter: annotationWriter ?? AnnotationWriter(database: annotationsDB),
            restoreCoordinator: restoreCoordinator ?? MutationCoordinator(
                database: libraryDB,
                backupRoot: libraryBackupRoot
            ),
            pdfSourceResolver: pdfSourceResolver,
            pdfWorkerClient: pdfWorkerClient
        )
    }

    package convenience init(
        libraryDB: URL?,
        annotationsDB: URL?,
        configurationFile: URL?,
        dependencies: AppleBooksDependencies,
        manageCollectionBooksApplication: Bool,
        manageAnnotationBooksApplication: Bool,
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws {
        try self.init(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: configurationFile,
            dependencies: dependencies,
            manageCollectionBooksApplication: manageCollectionBooksApplication,
            manageAnnotationBooksApplication: manageAnnotationBooksApplication,
            libraryBackupRoot: SQLiteBackup.defaultRoot(),
            collectionWriter: nil,
            annotationWriter: nil,
            restoreCoordinator: nil,
            pdfSourceResolver: PDFSourceResolver(),
            pdfWorkerClient: dependencies.contains(.pdfWorker) ? pdfWorkerURL.map {
                PDFWorkerClient(workerURL: $0, timeout: pdfWorkerTimeout ?? PDFWorkerClient.defaultTimeout)
            } : nil
        )
    }

    private init(
        libraryDB: URL?,
        annotationsDB: URL?,
        configurationFile: URL?,
        dependencies: AppleBooksDependencies,
        manageCollectionBooksApplication: Bool,
        manageAnnotationBooksApplication: Bool,
        libraryBackupRoot: URL,
        collectionWriter injectedCollectionWriter: CollectionWriter?,
        annotationWriter injectedAnnotationWriter: AnnotationWriter?,
        restoreCoordinator injectedRestoreCoordinator: MutationCoordinator?,
        pdfSourceResolver: PDFSourceResolver,
        pdfWorkerClient: PDFWorkerClient?
    ) throws {
        guard dependencies.needsLibraryDatabase == (libraryDB != nil),
              dependencies.needsAnnotationsDatabase == (annotationsDB != nil) else {
            throw AppleBooksDependencyError.invalidComposition
        }

        let libraryConnection = try dependencies.contains(.libraryRead)
            ? SQLiteConnection.readOnly(path: libraryDB!.path)
            : nil
        let annotationConnection = try dependencies.contains(.annotationsRead)
            ? SQLiteConnection.readOnly(path: annotationsDB!.path)
            : nil
        let selectedConfigurationFile = configurationFile ?? AppleBooksConfiguration.defaultFileURL
        let configuration = try dependencies.contains(.configuration)
            ? AppleBooksConfiguration(fileURL: selectedConfigurationFile)
            : .empty

        let books = libraryConnection.map(BookQueries.init(connection:))
        bookQueries = books
        collectionQueries = libraryConnection.map(CollectionQueries.init(connection:))
        self.annotationConnection = annotationConnection
        if let annotationConnection, let books, dependencies.contains(.configuration) {
            annotationQueries = AnnotationQueries(
                annotationConnection: annotationConnection,
                bookQueries: books,
                historicalAssets: configuration.historicalAssets,
                configuration: configuration,
                configurationFileURL: selectedConfigurationFile
            )
        } else {
            annotationQueries = nil
        }
        readingQueries = libraryConnection.map {
            ReadingQueries(connection: $0, annotationConnection: annotationConnection)
        }

        if dependencies.contains(.collectionWrite), let libraryDB {
            if let injectedCollectionWriter {
                collectionWriter = injectedCollectionWriter
            } else {
                let booksApp = manageCollectionBooksApplication ? BooksAppController.live : BooksAppController.detached
                collectionWriter = CollectionWriter(
                    database: libraryDB,
                    booksApp: booksApp,
                    cloudProjector: manageCollectionBooksApplication ? CollectionCloudProjector.live(libraryDatabase: libraryDB) : nil,
                    cloudSynchronizer: manageCollectionBooksApplication
                        ? CollectionCloudSynchronizer.live(libraryDatabase: libraryDB, booksApp: booksApp)
                        : nil
                )
            }
        } else {
            collectionWriter = nil
        }

        if dependencies.contains(.annotationWrite), let annotationsDB {
            if let injectedAnnotationWriter {
                annotationWriter = injectedAnnotationWriter
            } else {
                let booksApp = manageAnnotationBooksApplication ? BooksAppController.live : BooksAppController.detached
                annotationWriter = AnnotationWriter(
                    database: annotationsDB,
                    booksApp: booksApp,
                    cloudProjector: manageAnnotationBooksApplication ? AnnotationCloudProjector.live(annotationsDatabase: annotationsDB) : nil,
                    cloudSynchronizer: manageAnnotationBooksApplication
                        ? AnnotationCloudSynchronizer.live(annotationsDatabase: annotationsDB, booksApp: booksApp)
                        : nil
                )
            }
        } else {
            annotationWriter = nil
        }

        if dependencies.contains(.libraryBackup), let libraryDB {
            if let injectedRestoreCoordinator {
                restoreCoordinator = injectedRestoreCoordinator
            } else {
                let booksApp = manageCollectionBooksApplication ? BooksAppController.live : BooksAppController.detached
                restoreCoordinator = MutationCoordinator(database: libraryDB, backupRoot: libraryBackupRoot, booksApp: booksApp)
            }
        } else {
            restoreCoordinator = nil
        }

        libraryDatabase = libraryDB
        annotationsDatabase = annotationsDB
        self.libraryBackupRoot = libraryBackupRoot
        self.pdfSourceResolver = pdfSourceResolver
        self.pdfWorkerClient = dependencies.contains(.pdfWorker) ? pdfWorkerClient : nil
        self.dependencies = dependencies
        self.configuration = configuration
    }

    private func require<T>(_ component: T?, _ dependency: AppleBooksDependency) throws -> T {
        guard let component else { throw AppleBooksDependencyError.unavailable(dependency) }
        return component
    }

    private func requiredBookQueries() throws -> BookQueries {
        try require(bookQueries, .libraryRead)
    }

    private func requiredCollectionQueries() throws -> CollectionQueries {
        try require(collectionQueries, .libraryRead)
    }

    private func requiredAnnotationQueries() throws -> AnnotationQueries {
        try require(annotationQueries, .annotationsRead)
    }

    private func requiredReadingQueries() throws -> ReadingQueries {
        try require(readingQueries, .libraryRead)
    }

    private func requiredCollectionWriter() throws -> CollectionWriter {
        try require(collectionWriter, .collectionWrite)
    }

    private func requiredAnnotationWriter() throws -> AnnotationWriter {
        try require(annotationWriter, .annotationWrite)
    }

    private func requiredRestoreCoordinator() throws -> MutationCoordinator {
        try require(restoreCoordinator, .libraryBackup)
    }

    private func requiredLibraryDatabase() throws -> URL {
        try require(libraryDatabase, .libraryBackup)
    }

    private func requiredConfiguration() throws -> AppleBooksConfiguration {
        guard dependencies.contains(.configuration) else {
            throw AppleBooksDependencyError.unavailable(.configuration)
        }
        return configuration
    }

    public func listLibraryBackups() throws -> [LibraryBackup] {
        try SQLiteBackup.list(source: try requiredLibraryDatabase(), backupRoot: libraryBackupRoot)
    }

    public func restoreLibraryBackup(handle: String) throws -> RestoreResult {
        try requiredRestoreCoordinator().restoreLibrary(handle: handle)
    }

    // Stable deterministic order + validated pagination.
    public func listCollections(limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try requiredCollectionQueries().list(limit: limit, offset: offset)
    }

    package func semanticCollectionSummaryPage(
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<SemanticCollectionSummary> {
        try requiredCollectionQueries().semanticListPage(limit: limit, cursor: cursor)
    }

    // Missing or deleted collections return nil.
    public func collection(localPK: Int64) throws -> Collection? {
        try requiredCollectionQueries().getByLocalPK(localPK)
    }

    public func collection(collectionID: String) throws -> Collection? {
        try requiredCollectionQueries().getUniqueByCollectionID(collectionID)
    }

    package func semanticCollection(localPK: Int64) throws -> SemanticCollection? {
        try requiredCollectionQueries().semanticGetByLocalPK(localPK)
    }

    package func semanticCollection(collectionID: String) throws -> SemanticCollection? {
        try requiredCollectionQueries().semanticGetUniqueByCollectionID(collectionID)
    }

    // Title is a search field, never collection identity.
    public func collections(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try requiredCollectionQueries().searchTitle(text, limit: limit, offset: offset)
    }

    package func semanticCollectionSummaryPage(
        matchingTitle text: String,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<SemanticCollectionSummary> {
        try requiredCollectionQueries().semanticSearchTitlePage(text, limit: limit, cursor: cursor)
    }

    public func books(inCollectionLocalPK localPK: Int64) throws -> [Book]? {
        guard let collection = try requiredCollectionQueries().getByLocalPK(localPK) else { return nil }
        return try requiredCollectionQueries().books(in: collection)
    }

    public func books(inCollectionID collectionID: String) throws -> [Book]? {
        guard let collection = try requiredCollectionQueries().getUniqueByCollectionID(collectionID) else { return nil }
        return try requiredCollectionQueries().books(in: collection)
    }

    package func semanticBookSummaryPage(
        inCollectionLocalPK localPK: Int64,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<BookSummary>? {
        guard let collection = try requiredCollectionQueries().semanticGetByLocalPK(localPK) else { return nil }
        return try requiredCollectionQueries().semanticBooksPage(in: collection, limit: limit, cursor: cursor)
    }

    package func semanticBookSummaryPage(
        inCollectionID collectionID: String,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<BookSummary>? {
        guard let collection = try requiredCollectionQueries().semanticGetUniqueByCollectionID(collectionID) else { return nil }
        return try requiredCollectionQueries().semanticBooksPage(in: collection, limit: limit, cursor: cursor)
    }

    public func createCollection(
        title: String,
        details: String? = nil,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try requiredCollectionWriter().createCollection(
            title: title,
            details: details,
            syncCloud: syncCloud
        )
    }

    public func renameCollection(localPK: Int64, newTitle: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().renameCollection(
            localPK: localPK,
            newTitle: newTitle,
            syncCloud: syncCloud
        )
    }

    public func renameCollection(collectionID: String, newTitle: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().renameCollection(
            collectionID: collectionID,
            newTitle: newTitle,
            syncCloud: syncCloud
        )
    }

    public func deleteCollection(localPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().deleteCollection(
            localPK: localPK,
            syncCloud: syncCloud
        )
    }

    public func deleteCollection(collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().deleteCollection(
            collectionID: collectionID,
            syncCloud: syncCloud
        )
    }

    public func addBook(bookLocalPK: Int64, toCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().addBook(
            bookLocalPK: bookLocalPK,
            toCollectionLocalPK: collectionLocalPK,
            syncCloud: syncCloud
        )
    }

    public func addBook(assetID: String, toCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().addBook(
            assetID: assetID,
            toCollectionID: collectionID,
            syncCloud: syncCloud
        )
    }

    public func addBook(bookLocalPK: Int64, toCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().addBook(
            bookLocalPK: bookLocalPK,
            toCollectionID: collectionID,
            syncCloud: syncCloud
        )
    }

    public func addBook(assetID: String, toCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().addBook(
            assetID: assetID,
            toCollectionLocalPK: collectionLocalPK,
            syncCloud: syncCloud
        )
    }

    public func removeBook(bookLocalPK: Int64, fromCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().removeBook(
            bookLocalPK: bookLocalPK,
            fromCollectionLocalPK: collectionLocalPK,
            syncCloud: syncCloud
        )
    }

    public func removeBook(assetID: String, fromCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().removeBook(
            assetID: assetID,
            fromCollectionID: collectionID,
            syncCloud: syncCloud
        )
    }

    public func removeBook(bookLocalPK: Int64, fromCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().removeBook(
            bookLocalPK: bookLocalPK,
            fromCollectionID: collectionID,
            syncCloud: syncCloud
        )
    }

    public func removeBook(assetID: String, fromCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredCollectionWriter().removeBook(
            assetID: assetID,
            fromCollectionLocalPK: collectionLocalPK,
            syncCloud: syncCloud
        )
    }

    public func syncPendingCloudChanges() throws -> CloudSyncSummary {
        let collectionPending = try requiredCollectionWriter().pendingCloudChangeCount()
        let annotationPending = try requiredAnnotationWriter().pendingCloudChangeCount()
        do {
            if collectionPending > 0 {
                try requiredCollectionWriter().syncPendingCloudChanges()
            }
            if annotationPending > 0 {
                try requiredAnnotationWriter().syncPendingCloudChanges(restartRunningBooks: collectionPending == 0)
            }
        } catch is AppleBooksCloudSyncError {
            throw AppleBooksCloudSyncError.unavailable
        } catch {
            throw AppleBooksCloudSyncError.acknowledgementFailed
        }
        return CloudSyncSummary(
            collectionPendingBefore: collectionPending,
            annotationPendingBefore: annotationPending
        )
    }

    public func listBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredBookQueries().list(limit: limit, offset: offset)
    }

    public func annotatedBooks() throws -> [BookOverview] {
        let counts = try userAnnotationCountsByAssetID()
        return try requiredBookQueries().list().compactMap { book in
            guard let assetID = book.assetID,
                  let count = counts[assetID],
                  count > 0 else {
                return nil
            }
            return BookOverview(book: book, userAnnotationCount: count)
        }
    }

    public func bookOverview(localPK: Int64) throws -> BookOverview? {
        guard let book = try requiredBookQueries().getByLocalPK(localPK) else { return nil }
        let count = try book.assetID.map(requiredAnnotationAggregateQueries().userAnnotationCount(assetID:)) ?? 0
        return BookOverview(book: book, userAnnotationCount: count)
    }

    public func bookOverview(assetID: String) throws -> BookOverview? {
        guard let book = try requiredBookQueries().getUniqueByAssetID(assetID) else { return nil }
        let count = try requiredAnnotationAggregateQueries().userAnnotationCount(assetID: assetID)
        return BookOverview(book: book, userAnnotationCount: count)
    }

    public func libraryStats() throws -> LibraryStats {
        try makeLibraryStats(includeRichTop: true)
    }

    package func semanticLibraryStats() throws -> LibraryStats {
        try makeLibraryStats(includeRichTop: false)
    }

    private func makeLibraryStats(includeRichTop: Bool) throws -> LibraryStats {
        let bookQueries = try requiredBookQueries()
        let aggregate = try requiredAnnotationAggregateQueries()
        let partitions = try requiredReadingQueries().partitionCounts()
        let classification = try annotationClassificationCounts(
            aggregate: aggregate,
            bookQueries: bookQueries
        )
        let topSummaries = try topAnnotatedBookSummaries(
            aggregate: aggregate,
            bookQueries: bookQueries
        )
        let richTop: [BookOverview]
        if includeRichTop {
            richTop = try topSummaries.compactMap { summary -> BookOverview? in
                guard let book = try bookQueries.getByLocalPK(summary.localPK) else { return nil }
                return BookOverview(book: book, userAnnotationCount: summary.annotationCount)
            }
        } else {
            richTop = []
        }

        return LibraryStats(
            totalBooks: try bookQueries.totalCount(),
            finishedBooks: partitions.finished,
            inProgressBooks: partitions.inProgress,
            unstartedBooks: partitions.unstarted,
            totalUserAnnotations: classification.total,
            historicalAnnotationCount: classification.historical,
            unmappedAnnotationCount: classification.unmapped,
            ambiguousAnnotationCount: classification.ambiguous,
            identityUnavailableAnnotationCount: classification.identityUnavailable,
            topAnnotatedBooks: richTop,
            topAnnotatedBookSummaries: topSummaries
        )
    }

    public func bookPage(limit: Int? = nil, offset: Int = 0) throws -> Page<Book> {
        try requiredBookQueries().page(limit: limit, offset: offset)
    }

    public func bookSummaryPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try requiredBookQueries().summaryPage(limit: limit, cursor: cursor)
    }

    public func searchBookSummaries(
        _ text: String,
        field: BookSearchField = .all,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<BookSummary> {
        try requiredBookQueries().searchSummaryPage(text, field: field, limit: limit, cursor: cursor)
    }

    public func annotatedBookSummaryPage(
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<AnnotatedBookSummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let beforeGeneration = try annotatedBookCursorGeneration()
        let fingerprint = try CursorQueryFingerprint.make(
            kind: "books.annotated",
            fields: [CursorFingerprintField("order.version", .unsigned(1))]
        )
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )
        let startPK: Int64?
        if let locator = session.locator {
            guard locator.words.count == 1 else { throw CursorPaginationError.invalidCursor }
            startPK = Int64(bitPattern: locator.words[0])
        } else {
            startPK = nil
        }

        let bookQueries = try requiredBookQueries()
        let aggregate = try requiredAnnotationAggregateQueries()
        var candidates: [AnnotatedBookSummary] = []
        candidates.reserveCapacity(effectiveLimit + 1)
        var batch: [BookSummary] = []
        batch.reserveCapacity(AnnotationAggregateQueries.maximumIdentityBatch)
        var pageFilled = false

        func flushBatch() throws {
            guard batch.isEmpty == false else { return }
            let eligibleIDs = batch.compactMap { book in
                PublicStableIdentityPolicy.isEligible(book.assetID) ? book.assetID : nil
            }
            let multiplicity = try bookQueries.identityMultiplicity(assetIDs: eligibleIDs)
            let counts = try aggregate.userAnnotationCounts(assetIDs: eligibleIDs)
            for book in batch {
                guard let assetID = book.assetID,
                      PublicStableIdentityPolicy.isEligible(assetID),
                      let match = multiplicity[assetID],
                      match.count == 1,
                      match.uniqueLocalPK == book.localPK,
                      let count = counts[assetID], count > 0 else {
                    continue
                }
                candidates.append(AnnotatedBookSummary(book: book, userAnnotationCount: count))
                if candidates.count > effectiveLimit {
                    pageFilled = true
                    break
                }
            }
            batch.removeAll(keepingCapacity: true)
        }

        try bookQueries.forEachSummary(afterLocalPK: startPK) { book in
            batch.append(book)
            if batch.count == AnnotationAggregateQueries.maximumIdentityBatch {
                try flushBatch()
            }
            return pageFilled == false
        }
        if pageFilled == false {
            try flushBatch()
        }

        let afterGeneration = try annotatedBookCursorGeneration()
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            total: nil,
            session: session,
            afterGeneration: afterGeneration,
            locator: { try .rowID($0.book.localPK) }
        )
    }

    private func annotatedBookCursorGeneration() throws -> CursorGeneration {
        guard let libraryDatabase, let annotationsDatabase else {
            throw CursorPaginationError.generationUnavailable
        }
        return try CursorGeneration.compose([
            .sqlite(label: "library", databaseURL: libraryDatabase),
            .sqlite(label: "annotations", databaseURL: annotationsDatabase),
        ])
    }

    public func book(localPK: Int64) throws -> Book? {
        try requiredBookQueries().getByLocalPK(localPK)
    }

    public func book(assetID: String) throws -> Book? {
        try requiredBookQueries().getUniqueByAssetID(assetID)
    }

    package func semanticBookDetail(localPK: Int64) throws -> SemanticBookDetail? {
        try requiredBookQueries().semanticDetail(localPK: localPK)
    }

    package func semanticBookDetail(assetID: String) throws -> SemanticBookDetail? {
        try requiredBookQueries().semanticDetail(assetID: assetID)
    }

    public func pdfSources() throws -> [PDFSource] {
        pdfSourceResolver.resolve(pdfBooks: try requiredBookQueries().pdfBooks())
    }

    public func pdfSource(forBookLocalPK localPK: Int64) throws -> PDFSource? {
        let queries = try requiredBookQueries()
        guard try queries.pdfResourceTarget(localPK: localPK) != nil,
              let book = try queries.getByLocalPK(localPK) else {
            return nil
        }
        return pdfSourceResolver.resolve(book: book)
    }

    public func pdfSource(fileURL: URL) throws -> PDFSource? {
        pdfSourceResolver.resolve(fileURL: fileURL, pdfBooks: try requiredBookQueries().pdfBooks())
    }

    package func semanticPDFSourcePage(
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<PDFInventorySummary> {
        try pdfSourceResolver.inventoryPage(
            bookQueries: requiredBookQueries(),
            limit: limit,
            cursor: cursor
        )
    }

    package func semanticPDFSource(forBookLocalPK localPK: Int64) throws -> PDFSource? {
        let queries = try requiredBookQueries()
        guard let target = try queries.pdfResourceTarget(localPK: localPK) else { return nil }
        let summary = try queries.semanticSummary(localPK: localPK)
        return pdfSourceResolver.resolve(target: target, summary: summary)
    }

    package func semanticPDFSource(sourceID: PDFSourceID) throws -> PDFSource? {
        try pdfSourceResolver.resolve(sourceID: sourceID, bookQueries: requiredBookQueries())
    }

    package func semanticPDFSource(fileURL: URL) throws -> PDFSource? {
        pdfSourceResolver.resolve(
            fileURL: fileURL,
            pdfResources: try requiredBookQueries().semanticPDFResources()
        )
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
            bookQueries: try requiredBookQueries(),
            sourceResolver: pdfSourceResolver,
            workerClient: pdfWorkerClient
        )
    }

    public func exportBundle(options: ExportOptions) throws -> ExportBundle {
        let pdfService: PDFHighlightService?
        if let pdfWorkerClient {
            pdfService = PDFHighlightService(
                bookQueries: try requiredBookQueries(),
                sourceResolver: pdfSourceResolver,
                workerClient: pdfWorkerClient
            )
        } else {
            pdfService = nil
        }
        return try ExportService(
            annotationQueries: annotationQueries,
            bookQueries: try requiredBookQueries(),
            configuration: dependencies.contains(.configuration) ? configuration : nil,
            pdfService: pdfService
        ).makeBundle(options: options)
    }

    public func books(matchingTitle text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredBookQueries().searchTitle(text, limit: limit, offset: offset)
    }

    public func books(matchingGenre text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredBookQueries().searchGenre(text, limit: limit, offset: offset)
    }

    public func books(matching text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredBookQueries().search(text, limit: limit, offset: offset)
    }

    public func contentStatus(forBookLocalPK localPK: Int64) throws -> EPUBContentStatus? {
        guard let book = try requiredBookQueries().getForContent(localPK) else { return nil }
        return EPUBContentInspector.status(book: book, configuration: try requiredConfiguration())
    }

    package func semanticContentStatus(forBookLocalPK localPK: Int64) throws -> EPUBContentStatus? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return EPUBContentInspector.status(target: target, configuration: try requiredConfiguration())
    }

    public func contentMetadata(forBookLocalPK localPK: Int64) throws -> EPUBMetadataInspection? {
        guard let book = try requiredBookQueries().getForContent(localPK) else { return nil }
        return try EPUBContentInspector.metadata(book: book, configuration: try requiredConfiguration())
    }

    package func semanticContentMetadata(forBookLocalPK localPK: Int64) throws -> SemanticEPUBMetadataInspection? {
        let queries = try requiredBookQueries()
        guard let book = try queries.semanticDetail(localPK: localPK),
              let target = try queries.resourceTarget(localPK: localPK) else { return nil }
        return try EPUBContentInspector.metadata(
            target: target,
            book: book,
            configuration: try requiredConfiguration()
        )
    }

    public func contentCover(forBookLocalPK localPK: Int64) throws -> EPUBCoverInspection? {
        guard let book = try requiredBookQueries().getForContent(localPK) else { return nil }
        return try EPUBContentInspector.cover(book: book, configuration: try requiredConfiguration())
    }

    package func semanticContentCover(forBookLocalPK localPK: Int64) throws -> EPUBCoverInspection? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return try EPUBContentInspector.cover(target: target, configuration: try requiredConfiguration())
    }

    public func locate(rawCFI: String, forBookLocalPK localPK: Int64) throws -> EPUBLocationInspection? {
        guard let book = try requiredBookQueries().getForContent(localPK) else { return nil }
        return try EPUBContentInspector.locate(rawCFI: rawCFI, book: book, configuration: try requiredConfiguration())
    }

    package func semanticLocate(rawCFI: String, forBookLocalPK localPK: Int64) throws -> EPUBLocationInspection? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return try EPUBContentInspector.locate(
            rawCFI: rawCFI,
            target: target,
            configuration: try requiredConfiguration()
        )
    }

    public func bookContent(forBookLocalPK localPK: Int64) throws -> BookContent {
        guard let book = try requiredBookQueries().getForContent(localPK) else {
            throw ContentError.bookPathUnavailable
        }
        return try bookContent(for: book)
    }

    private func bookContent(for book: Book) throws -> BookContent {
        try BookContent(reader: EPUBSourceResolver.reader(for: book, configuration: try requiredConfiguration()))
    }

    package func semanticBookContent(forBookLocalPK localPK: Int64) throws -> BookContent {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK), target.path != nil else {
            throw ContentError.bookPathUnavailable
        }
        return try BookContent(
            reader: EPUBSourceResolver.reader(for: target, configuration: try requiredConfiguration())
        )
    }

    public func listAnnotations(
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().list(scope: scope, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticList(scope: scope, limit: limit, offset: offset)
    }

    package func semanticAnnotationPage(
        _ request: AnnotationQueryRequest
    ) throws -> CursorPage<SemanticAnnotation> {
        try requiredAnnotationQueries().semanticPage(request)
    }

    package func semanticAnnotation(
        localPK: Int64,
        scope: AnnotationScope = .user
    ) throws -> SemanticAnnotation? {
        try requiredAnnotationQueries().semanticGetByLocalPK(localPK, scope: scope)
    }

    package func semanticAnnotation(
        uuid: String,
        scope: AnnotationScope = .user
    ) throws -> SemanticAnnotation? {
        try requiredAnnotationQueries().semanticGetUniqueByUUID(uuid, scope: scope)
    }

    public func annotationPage(
        scope: AnnotationScope = .activeRaw,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> Page<EnrichedAnnotation> {
        try requiredAnnotationQueries().page(scope: scope, limit: limit, offset: offset)
    }

    public func annotationPage(
        colorName: String,
        scope: AnnotationScope = .activeRaw,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> Page<EnrichedAnnotation> {
        try requiredAnnotationQueries().page(colorName: colorName, scope: scope, limit: limit, offset: offset)
    }

    public func annotation(localPK: Int64, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        try requiredAnnotationQueries().getByLocalPK(localPK, scope: scope)
    }

    public func updateAnnotationNote(localPK: Int64, note: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredAnnotationWriter().updateNote(localPK: localPK, note: note, syncCloud: syncCloud)
    }

    public func updateAnnotationNote(uuid: String, note: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredAnnotationWriter().updateNote(uuid: uuid, note: note, syncCloud: syncCloud)
    }

    public func deleteAnnotation(localPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try requiredAnnotationWriter().delete(localPK: localPK, syncCloud: syncCloud)
    }

    public func deleteAnnotation(uuid: String, syncCloud: Bool = false) throws -> MutationResult {
        try requiredAnnotationWriter().delete(uuid: uuid, syncCloud: syncCloud)
    }

    public func annotation(uuid: String, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        try requiredAnnotationQueries().getUniqueByUUID(uuid, scope: scope)
    }

    public func annotations(
        bookAssetID: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().byAssetID(bookAssetID, scope: scope, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        bookAssetID: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticByAssetID(bookAssetID, scope: scope, limit: limit, offset: offset)
    }

    public func annotations(
        bookLocalPK: Int64,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try requiredBookQueries().getByLocalPK(bookLocalPK), let assetID = book.assetID else { return [] }
        return try requiredAnnotationQueries().byAssetID(assetID, scope: scope, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        bookLocalPK: Int64,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let assetID = try requiredBookQueries().semanticAssetID(localPK: bookLocalPK) else { return [] }
        return try requiredAnnotationQueries().semanticByAssetID(assetID, scope: scope, limit: limit, offset: offset)
    }

    package func semanticAnnotationsInReadingOrder(
        bookLocalPK: Int64,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        let bookQueries = try requiredBookQueries()
        guard let assetID = try bookQueries.semanticAssetID(localPK: bookLocalPK) else { return [] }
        let annotations = try requiredAnnotationQueries().semanticByAssetID(assetID, scope: .user)
        guard annotations.isEmpty == false else { return [] }

        var chapterOrder: [String: Int] = [:]
        if let target = try bookQueries.resourceTarget(localPK: bookLocalPK), target.path != nil {
            do {
                let content = try BookContent(
                    reader: EPUBSourceResolver.reader(for: target, configuration: try requiredConfiguration())
                )
                for chapter in try content.listChapters() {
                    chapterOrder[chapter.id] = min(chapterOrder[chapter.id] ?? .max, chapter.order)
                }
            } catch {
                chapterOrder.removeAll(keepingCapacity: false)
            }
        }

        let sorted = annotations.sorted { lhs, rhs in
            let left = EPUBAnnotationReadingKey.make(
                rawCFI: lhs.rawCFI,
                chapterOrder: chapterOrder,
                createdAt: lhs.createdAt,
                localPK: lhs.localPK
            )
            let right = EPUBAnnotationReadingKey.make(
                rawCFI: rhs.rawCFI,
                chapterOrder: chapterOrder,
                createdAt: rhs.createdAt,
                localPK: rhs.localPK
            )
            return EPUBAnnotationReadingKey.lessThan(left, right)
        }
        let paged = sorted.dropFirst(offset)
        guard let limit else { return Array(paged) }
        return Array(paged.prefix(limit))
    }

    public func annotationsInReadingOrder(
        bookLocalPK: Int64,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try requiredBookQueries().getByLocalPK(bookLocalPK) else { return [] }
        return try annotationsInReadingOrder(book: book, limit: limit, offset: offset)
    }

    public func annotationsInReadingOrder(
        bookAssetID assetID: String,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        guard let book = try requiredBookQueries().getUniqueByAssetID(assetID) else { return [] }
        return try annotationsInReadingOrder(book: book, limit: limit, offset: offset)
    }

    private func annotationsInReadingOrder(
        book: Book,
        limit: Int?,
        offset: Int
    ) throws -> [EnrichedAnnotation] {
        guard let assetID = book.assetID else { return [] }
        let annotations = try requiredAnnotationQueries().byAssetID(assetID, scope: .user)
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
            let left = EPUBAnnotationReadingKey.make(
                rawCFI: lhs.annotation.location?.rawCFI,
                chapterOrder: chapterOrder,
                createdAt: lhs.annotation.createdAt,
                localPK: lhs.annotation.localPK
            )
            let right = EPUBAnnotationReadingKey.make(
                rawCFI: rhs.annotation.location?.rawCFI,
                chapterOrder: chapterOrder,
                createdAt: rhs.annotation.createdAt,
                localPK: rhs.annotation.localPK
            )
            return EPUBAnnotationReadingKey.lessThan(left, right)
        }
        let paged = sorted.dropFirst(offset)
        guard let limit else { return Array(paged) }
        return Array(paged.prefix(limit))
    }

    package func semanticAnnotationContext(
        localPK: Int64,
        charsBefore: Int = 300,
        charsAfter: Int = 300
    ) throws -> AnnotationContext {
        guard charsBefore >= 0, charsAfter >= 0 else {
            throw AnnotationContextError.invalidWindow
        }
        guard let annotation = try requiredAnnotationQueries().semanticGetByLocalPK(localPK) else {
            throw AnnotationContextError.annotationUnavailable
        }
        guard let assetID = annotation.rawAssetID else {
            throw AnnotationContextError.assetIdentityUnavailable
        }
        let queries = try requiredBookQueries()
        let book: SemanticBookDetail
        do {
            guard let resolved = try queries.semanticDetail(assetID: assetID) else {
                throw AnnotationContextError.currentBookUnavailable
            }
            book = resolved
        } catch StableIdentityError.ambiguousBookAssetID {
            throw AnnotationContextError.currentBookAmbiguous
        }
        guard let target = try queries.resourceTarget(localPK: book.localPK), target.path != nil else {
            throw AnnotationContextError.contentPathUnavailable
        }
        guard let chapterID = annotation.chapterID else {
            throw AnnotationContextError.chapterUnavailable
        }

        let content = try semanticBookContent(forBookLocalPK: book.localPK)
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

    public func annotationContext(
        localPK: Int64,
        charsBefore: Int = 300,
        charsAfter: Int = 300
    ) throws -> AnnotationContext {
        guard charsBefore >= 0, charsAfter >= 0 else {
            throw AnnotationContextError.invalidWindow
        }
        guard let enriched = try requiredAnnotationQueries().getByLocalPK(localPK) else {
            throw AnnotationContextError.annotationUnavailable
        }
        let annotation = enriched.annotation
        guard let assetID = annotation.rawAssetID else {
            throw AnnotationContextError.assetIdentityUnavailable
        }
        let book: Book
        do {
            guard let resolved = try requiredBookQueries().getUniqueByAssetID(assetID) else {
                throw AnnotationContextError.currentBookUnavailable
            }
            book = resolved
        } catch StableIdentityError.ambiguousBookAssetID {
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
        try requiredAnnotationQueries().byColorName(colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingHighlightedText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().searchHighlightedText(text, colorName: colorName, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        matchingHighlightedText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticSearchHighlightedText(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingNote text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().searchNote(text, colorName: colorName, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        matchingNote text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticSearchNote(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().searchText(text, colorName: colorName, limit: limit, offset: offset)
    }

    package func semanticAnnotations(
        matchingText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticSearchText(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func recentlyCreatedAnnotations(limit: Int? = 10, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().recentlyCreated(limit: limit, offset: offset)
    }

    public func recentlyModifiedAnnotations() throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().recentlyModified()
    }

    package func semanticRecentlyCreatedAnnotations(limit: Int? = 10, offset: Int = 0) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticRecentlyCreated(limit: limit, offset: offset)
    }

    package func semanticRecentlyModifiedAnnotations() throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticRecentlyModified()
    }

    public func annotations(
        createdAtOrAfter lowerInclusive: Date? = nil,
        beforeExclusive upperExclusive: Date? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().created(
            lowerInclusive: lowerInclusive,
            upperExclusive: upperExclusive,
            limit: limit,
            offset: offset
        )
    }

    package func semanticAnnotations(
        createdAtOrAfter lowerInclusive: Date? = nil,
        beforeExclusive upperExclusive: Date? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try requiredAnnotationQueries().semanticCreated(
            lowerInclusive: lowerInclusive,
            upperExclusive: upperExclusive,
            limit: limit,
            offset: offset
        )
    }

    package func semanticBookSummariesInCanonicalOrder() throws -> [BookSummary] {
        let queries = try requiredBookQueries()
        var summaries: [BookSummary] = []
        try queries.forEachSummary(afterLocalPK: nil) { summary in
            summaries.append(summary)
            return true
        }
        return summaries
    }

    public func booksInProgress(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredReadingQueries().inProgress(limit: limit, offset: offset)
    }

    public func finishedBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredReadingQueries().finished(limit: limit, offset: offset)
    }

    public func unstartedBooks(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try requiredReadingQueries().unstarted(limit: limit, offset: offset)
    }

    public func recentlyReadBooks(limit: Int = 10, offset: Int = 0) throws -> [Book] {
        try requiredReadingQueries().recentlyRead(limit: limit, offset: offset)
    }

    package func semanticBooksInProgress(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try requiredReadingQueries().semanticInProgress(limit: limit, offset: offset)
    }

    package func semanticFinishedBooks(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try requiredReadingQueries().semanticFinished(limit: limit, offset: offset)
    }

    package func semanticUnstartedBooks(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try requiredReadingQueries().semanticUnstarted(limit: limit, offset: offset)
    }

    package func semanticRecentlyReadBooks(limit: Int = 10, offset: Int = 0) throws -> [BookSummary] {
        try requiredReadingQueries().semanticRecentlyRead(limit: limit, offset: offset)
    }

    package func semanticBooksInProgressPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try requiredReadingQueries().semanticInProgressPage(limit: limit, cursor: cursor)
    }

    package func semanticFinishedBooksPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try requiredReadingQueries().semanticFinishedPage(limit: limit, cursor: cursor)
    }

    package func semanticUnstartedBooksPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try requiredReadingQueries().semanticUnstartedPage(limit: limit, cursor: cursor)
    }

    package func semanticRecentlyReadBooksPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try requiredReadingQueries().semanticRecentlyReadPage(limit: limit, cursor: cursor)
    }

    public func currentReadingLocation(forBookLocalPK localPK: Int64) throws -> Annotation? {
        guard let assetID = try requiredBookQueries().semanticAssetID(localPK: localPK) else {
            return nil
        }
        return try requiredReadingQueries().currentPosition(rawAssetID: assetID)
    }

    private func userAnnotationCountsByAssetID() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try requiredAnnotationAggregateQueries().forEachUserAnnotationAssetCount { group in
            guard let assetID = group.rawAssetID else { return }
            counts[assetID] = group.count
        }
        return counts
    }

    private func requiredAnnotationAggregateQueries() throws -> AnnotationAggregateQueries {
        guard let annotationConnection else {
            throw AppleBooksDependencyError.unavailable(.annotationsRead)
        }
        return AnnotationAggregateQueries(connection: annotationConnection)
    }

    private struct AnnotationClassificationCounts {
        var total = 0
        var historical = 0
        var unmapped = 0
        var ambiguous = 0
        var identityUnavailable = 0
    }

    private func annotationClassificationCounts(
        aggregate: AnnotationAggregateQueries,
        bookQueries: BookQueries
    ) throws -> AnnotationClassificationCounts {
        let classifier = AnnotationSourceClassifier(
            bookQueries: bookQueries,
            historicalAssets: configuration.historicalAssets
        )
        var result = AnnotationClassificationCounts()
        var batch: [UserAnnotationAssetCount] = []
        batch.reserveCapacity(AnnotationSourceClassifier.maximumBatch)

        func apply(_ state: AnnotationAssetSourceState, count: Int, to result: inout AnnotationClassificationCounts) throws {
            switch state {
            case .current:
                break
            case .historical:
                result.historical += count
            case .unmapped:
                result.unmapped += count
            case .ambiguousCurrent:
                result.ambiguous += count
            case .identityUnavailable:
                result.identityUnavailable += count
            case .schemaUnavailable:
                throw AnnotationSourceClassificationError.schemaUnavailable
            }
        }

        func flush(_ groups: inout [UserAnnotationAssetCount], into result: inout AnnotationClassificationCounts) throws {
            guard groups.isEmpty == false else { return }
            let assetIDs = groups.compactMap(\.rawAssetID)
            let classified = try classifier.classify(assetIDs)
            for group in groups {
                guard let assetID = group.rawAssetID,
                      let state = classified[assetID] else {
                    throw AnnotationSourceClassificationError.schemaUnavailable
                }
                try apply(state, count: group.count, to: &result)
            }
            groups.removeAll(keepingCapacity: true)
        }

        try aggregate.forEachUserAnnotationAssetCount { group in
            result.total += group.count
            if group.identityUnavailable {
                try apply(.identityUnavailable, count: group.count, to: &result)
                return
            }
            if let immediate = classifier.classifyRawIdentity(group.rawAssetID) {
                try apply(immediate, count: group.count, to: &result)
                return
            }
            batch.append(group)
            if batch.count == AnnotationSourceClassifier.maximumBatch {
                try flush(&batch, into: &result)
            }
        }
        try flush(&batch, into: &result)
        return result
    }

    private struct RankedTopAnnotatedBook {
        let summary: TopAnnotatedBookSummary
        let canonicalOrder: Int
    }

    private func topAnnotatedBookSummaries(
        aggregate: AnnotationAggregateQueries,
        bookQueries: BookQueries
    ) throws -> [TopAnnotatedBookSummary] {
        var top: [RankedTopAnnotatedBook] = []
        top.reserveCapacity(5)
        var canonicalOrder = 0
        var batch: [BookIdentityRow] = []
        batch.reserveCapacity(AnnotationAggregateQueries.maximumIdentityBatch)

        func flushBatch() throws {
            guard batch.isEmpty == false else { return }
            let eligibleIDs = batch.compactMap { row in
                PublicStableIdentityPolicy.isEligible(row.assetID) ? row.assetID : nil
            }
            let multiplicity = try bookQueries.identityMultiplicity(assetIDs: eligibleIDs)
            let counts = try aggregate.userAnnotationCounts(assetIDs: eligibleIDs)
            for row in batch {
                defer { canonicalOrder += 1 }
                guard let assetID = row.assetID,
                      PublicStableIdentityPolicy.isEligible(assetID),
                      let match = multiplicity[assetID],
                      match.count == 1,
                      match.uniqueLocalPK == row.localPK,
                      let count = counts[assetID], count > 0 else {
                    continue
                }
                top.append(RankedTopAnnotatedBook(
                    summary: TopAnnotatedBookSummary(
                        localPK: row.localPK,
                        assetID: assetID,
                        annotationCount: count
                    ),
                    canonicalOrder: canonicalOrder
                ))
                top.sort { lhs, rhs in
                    if lhs.summary.annotationCount != rhs.summary.annotationCount {
                        return lhs.summary.annotationCount > rhs.summary.annotationCount
                    }
                    return lhs.canonicalOrder < rhs.canonicalOrder
                }
                if top.count > 5 { top.removeLast() }
            }
            batch.removeAll(keepingCapacity: true)
        }

        try bookQueries.forEachIdentity { row in
            batch.append(row)
            if batch.count == AnnotationAggregateQueries.maximumIdentityBatch {
                try flushBatch()
            }
            return true
        }
        try flushBatch()
        return top.map(\.summary)
    }

    package func semanticCurrentReadingChapter(forBookLocalPK localPK: Int64) throws -> Chapter? {
        guard let assetID = try requiredBookQueries().semanticAssetID(localPK: localPK),
              let bookmark = try requiredReadingQueries().semanticCurrentLocation(rawAssetID: assetID),
              let chapterID = bookmark.chapterID else {
            return nil
        }
        return try CurrentReadingChapter.resolve(
            chapterID: chapterID,
            in: semanticBookContent(forBookLocalPK: localPK)
        )
    }

    public func currentReadingChapter(forBookLocalPK localPK: Int64) throws -> Chapter? {
        guard let bookmark = try currentReadingLocation(forBookLocalPK: localPK),
              let chapterID = bookmark.location?.chapterID else {
            return nil
        }
        let content = try bookContent(forBookLocalPK: localPK)
        return try CurrentReadingChapter.resolve(chapterID: chapterID, in: content)
    }

    package func semanticCurrentReadingPosition(forBookLocalPK localPK: Int64) throws -> ReadingPosition? {
        let bookQueries = try requiredBookQueries()
        guard let assetID = try bookQueries.semanticAssetID(localPK: localPK) else { return nil }

        if let bookmark = try requiredReadingQueries().semanticCurrentLocation(rawAssetID: assetID),
           let chapterID = bookmark.chapterID {
            let chapters = try semanticBookContent(forBookLocalPK: localPK).listChapters()
            if let chapter = chapters.first(where: { $0.id == chapterID }) {
                return ReadingPosition(
                    chapterID: chapter.id,
                    title: chapter.title,
                    order: chapter.order,
                    totalChapters: chapters.count,
                    source: .bookmarkToc
                )
            }
            return ReadingPosition(
                chapterID: chapterID,
                title: nil,
                order: nil,
                totalChapters: nil,
                source: .bookmarkHint
            )
        }

        let candidate = try requiredAnnotationQueries().semanticByAssetID(assetID, scope: .user)
            .filter { $0.chapterID != nil }
            .sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case let (left?, right?) where left != right: return left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.localPK > rhs.localPK
                }
            }
            .first
        guard let candidate, let chapterID = candidate.chapterID else { return nil }
        let chapters = try semanticBookContent(forBookLocalPK: localPK).listChapters()
        return ReadingPosition(
            chapterID: chapterID,
            title: chapters.first(where: { $0.id == chapterID })?.title,
            order: nil,
            totalChapters: nil,
            source: .recentAnnotationInference
        )
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

        guard let book = try requiredBookQueries().getForCurrentReadingLocation(localPK),
              let assetID = book.assetID else {
            return nil
        }
        let candidate = try requiredAnnotationQueries().byAssetID(assetID, scope: .user)
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
