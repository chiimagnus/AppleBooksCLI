import Foundation

public enum StableIdentityError: Error, Equatable, Sendable {
    case ambiguousBookAssetID
    case ambiguousCollectionID
    case ambiguousAnnotationUUID
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

    public func restoreLibraryBackup(backupID: String) throws -> RestoreResult {
        let database = try requiredLibraryDatabase()
        let handle = try SQLiteBackup.restoreHandle(backupID: backupID, destination: database)
        return try requiredRestoreCoordinator().restoreLibrary(handle: handle)
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

    package func semanticPDFSource(bookAssetID assetID: String) throws -> PDFSource? {
        try pdfSourceResolver.resolve(bookAssetID: assetID, bookQueries: requiredBookQueries())
    }

    package func semanticPDFSource(sourceID: PDFSourceID) throws -> PDFSource? {
        try pdfSourceResolver.resolve(sourceID: sourceID, bookQueries: requiredBookQueries())
    }

    package func semanticPDFHighlightPage(
        source: PDFSource,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> SemanticPDFHighlightPage {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let identity = try pdfHighlightCursorIdentity(source)
        let cursorGeneration = try CursorGeneration.compose([
            .synthetic(label: "pdf-highlight-cursor", value: "v2"),
        ])
        let fingerprint = try CursorQueryFingerprint.make(
            kind: "pdf.highlights",
            fields: [
                CursorFingerprintField("order.version", .unsigned(1)),
                CursorFingerprintField("source.kind", .string(identity.kind)),
                CursorFingerprintField("source.value", .string(identity.value)),
            ]
        )
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: cursorGeneration
        )
        let state = try pdfHighlightWorkerState(from: session.locator)
        let workerPage: PDFAgentWorkerPage
        do {
            workerPage = try pdfHighlightService().readAgentPage(
                source: source,
                limit: effectiveLimit,
                continuation: state.traversal,
                generation: state.generation
            )
        } catch PDFWorkerClientError.workerFailure(.staleSource) {
            throw CursorPaginationError.staleCursor
        }
        let nextLocator: CursorLocator?
        if workerPage.hasMore {
            guard let traversal = workerPage.nextTraversal else {
                throw CursorPaginationError.internalContractFailure
            }
            nextLocator = try pdfHighlightLocator(
                traversal: traversal,
                generation: workerPage.generation
            )
        } else {
            nextLocator = nil
        }
        let nextCursor = try session.nextCursor(
            after: cursorGeneration,
            hasMore: workerPage.hasMore,
            locator: nextLocator
        )
        return SemanticPDFHighlightPage(
            bookAssetID: identity.kind == "book" ? identity.value : nil,
            pdfSourceID: identity.kind == "source" ? identity.value : nil,
            items: workerPage.items,
            nextCursor: nextCursor,
            hasMore: workerPage.hasMore
        )
    }

    private func pdfHighlightCursorIdentity(_ source: PDFSource) throws -> (kind: String, value: String) {
        if let rawSourceID = source.pdfSourceID {
            _ = try PDFSourceID.parse(rawSourceID)
            return ("source", rawSourceID)
        }
        let assetID = source.bookSummary?.assetID ?? source.book?.assetID
        guard let assetID, PublicStableIdentityPolicy.isEligible(assetID) else {
            throw CursorPaginationError.internalContractFailure
        }
        return ("book", assetID)
    }

    private func pdfHighlightWorkerState(
        from locator: CursorLocator?
    ) throws -> (traversal: PDFWorkerTraversal?, generation: String?) {
        guard let locator else { return (nil, nil) }
        let words = locator.words
        guard words.count == 7, words[0] == 1,
              words[1] <= UInt64(Int.max), words[2] <= UInt64(Int.max) else {
            throw CursorPaginationError.invalidCursor
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in words[3...] {
            for shift in stride(from: 56, through: 0, by: -8) {
                digest.append(UInt8((word >> UInt64(shift)) & 0xff))
            }
        }
        guard let generation = PDFWorkerProtocol.generationToken(digestBytes: digest) else {
            throw CursorPaginationError.invalidCursor
        }
        return (
            PDFWorkerTraversal(pageIndex: Int(words[1]), annotationIndex: Int(words[2])),
            generation
        )
    }

    private func pdfHighlightLocator(
        traversal: PDFWorkerTraversal,
        generation: String
    ) throws -> CursorLocator {
        guard traversal.pageIndex >= 0, traversal.annotationIndex >= 0,
              let digest = PDFWorkerProtocol.generationDigestBytes(generation), digest.count == 32 else {
            throw CursorPaginationError.internalContractFailure
        }
        var words: [UInt64] = [
            1,
            UInt64(traversal.pageIndex),
            UInt64(traversal.annotationIndex),
        ]
        for start in stride(from: 0, to: digest.count, by: 8) {
            var word: UInt64 = 0
            for byte in digest[start..<(start + 8)] {
                word = (word << 8) | UInt64(byte)
            }
            words.append(word)
        }
        return try CursorLocator(words: words)
    }

    private func pdfHighlightService() throws -> PDFHighlightService {
        PDFHighlightService(workerClient: try require(pdfWorkerClient, .pdfWorker))
    }

    package func exportDependencies(options: ExportOptions) throws -> AppleBooksDependencies {
        if options.bookSelectors.isEmpty {
            switch options.source {
            case .epub: return [.libraryRead, .annotationsRead, .configuration]
            case .pdf: return [.libraryRead, .pdfWorker]
            case .all: return [.libraryRead, .annotationsRead, .configuration, .pdfWorker]
            }
        }
        let sources = try ExportSourceResolver(
            bookQueries: requiredBookQueries(), pdfSourceResolver: pdfSourceResolver
        ).resolve(options.bookSelectors)
        var required: AppleBooksDependencies = .libraryRead
        for source in sources {
            if source.pdfSource != nil { required.insert(.pdfWorker) }
            else { required.formUnion([.annotationsRead, .configuration]) }
        }
        return required
    }

    public func exportBundle(options: ExportOptions) throws -> ExportBundle {
        let pdfService: PDFHighlightService?
        if let pdfWorkerClient {
            pdfService = PDFHighlightService(workerClient: pdfWorkerClient)
        } else {
            pdfService = nil
        }
        return try ExportService(
            annotationQueries: annotationQueries,
            bookQueries: try requiredBookQueries(),
            configuration: dependencies.contains(.configuration) ? configuration : nil,
            pdfService: pdfService,
            pdfSourceResolver: pdfSourceResolver
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

    package func semanticContentMetadata(bookAssetID assetID: String) throws -> SemanticEPUBMetadataInspection? {
        let queries = try requiredBookQueries()
        guard let target = try queries.uniqueResourceTarget(assetID: assetID) else { return nil }
        return try semanticContentMetadata(target: target, queries: queries)
    }

    package func semanticContentMetadata(bookLocalPK localPK: Int64) throws -> SemanticEPUBMetadataInspection? {
        let queries = try requiredBookQueries()
        guard let target = try queries.resourceTarget(localPK: localPK) else { return nil }
        return try semanticContentMetadata(target: target, queries: queries)
    }

    private func semanticContentMetadata(
        target: BookResourceTarget,
        queries: BookQueries
    ) throws -> SemanticEPUBMetadataInspection {
        guard target.path != nil else { throw ContentError.bookPathUnavailable }
        let fallback = try queries.contentMetadataFallback(localPK: target.localPK)
            ?? BookContentMetadataFallback(title: nil, author: nil, language: nil, releaseDate: nil, byteTruncatedFields: [])
        return try EPUBContentInspector.metadata(
            target: target,
            databaseFallback: fallback,
            configuration: try requiredConfiguration()
        )
    }

    public func contentCover(forBookLocalPK localPK: Int64) throws -> EPUBCoverInspection? {
        guard let book = try requiredBookQueries().getForContent(localPK) else { return nil }
        return try EPUBContentInspector.cover(book: book, configuration: try requiredConfiguration())
    }

    package func semanticContentCover(bookAssetID assetID: String) throws -> EPUBCoverInspection? {
        guard let target = try requiredBookQueries().uniqueResourceTarget(assetID: assetID) else { return nil }
        return try semanticContentCover(target: target)
    }

    package func semanticContentCover(bookLocalPK localPK: Int64) throws -> EPUBCoverInspection? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return try semanticContentCover(target: target)
    }

    private func semanticContentCover(target: BookResourceTarget) throws -> EPUBCoverInspection? {
        guard target.path != nil else { throw ContentError.bookPathUnavailable }
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

    package func semanticChapterListPage(
        bookAssetID assetID: String,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> SemanticChapterListPage? {
        guard let target = try requiredBookQueries().uniqueResourceTarget(assetID: assetID) else { return nil }
        return try semanticChapterListPage(
            target: target,
            selector: .assetID(assetID),
            limit: limit,
            cursor: cursor
        )
    }

    package func semanticChapterListPage(
        bookLocalPK localPK: Int64,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> SemanticChapterListPage? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return try semanticChapterListPage(
            target: target,
            selector: .localPK(localPK),
            limit: limit,
            cursor: cursor
        )
    }

    package func semanticChapterPage(
        bookAssetID assetID: String,
        chapterOrder: Int,
        maximumCharacters: Int? = nil,
        cursor: String? = nil
    ) throws -> SemanticChapterContinuationPage? {
        guard let target = try requiredBookQueries().uniqueResourceTarget(assetID: assetID) else { return nil }
        return try semanticChapterPage(
            target: target,
            selector: .assetID(assetID),
            chapterOrder: chapterOrder,
            maximumCharacters: maximumCharacters,
            cursor: cursor
        )
    }

    package func semanticChapterPage(
        bookLocalPK localPK: Int64,
        chapterOrder: Int,
        maximumCharacters: Int? = nil,
        cursor: String? = nil
    ) throws -> SemanticChapterContinuationPage? {
        guard let target = try requiredBookQueries().resourceTarget(localPK: localPK) else { return nil }
        return try semanticChapterPage(
            target: target,
            selector: .localPK(localPK),
            chapterOrder: chapterOrder,
            maximumCharacters: maximumCharacters,
            cursor: cursor
        )
    }

    private enum ContentBookSelector {
        case assetID(String)
        case localPK(Int64)
    }

    private func semanticChapterListPage(
        target: BookResourceTarget,
        selector: ContentBookSelector,
        limit: Int?,
        cursor: String?
    ) throws -> SemanticChapterListPage {
        guard target.path != nil else { throw ContentError.bookPathUnavailable }
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let selected = try EPUBSourceResolver.resolve(
            for: target,
            configuration: try requiredConfiguration()
        ).requireReader()
        let content = try BookContent(reader: selected.reader)
        let beforeGeneration = try CursorGeneration.compose([
            content.chapterListCursorGenerationComponent(),
        ])
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: try chapterListFingerprint(selector: selector),
            generation: beforeGeneration
        )
        let anchorOrder = try chapterListOrder(from: session.locator)
        let chapters = try content.listChapters()
        var previousOrder = 0
        for chapter in chapters {
            guard chapter.order > previousOrder else {
                throw CursorPaginationError.internalContractFailure
            }
            previousOrder = chapter.order
        }
        if let anchorOrder,
           chapters.contains(where: { $0.order == anchorOrder }) == false {
            throw CursorPaginationError.staleCursor
        }
        let candidates = Array(
            chapters.lazy
                .filter { chapter in anchorOrder.map { chapter.order > $0 } ?? true }
                .prefix(effectiveLimit + 1)
                .map {
                    SemanticChapterSummary(
                        chapterOrder: $0.order,
                        title: $0.title,
                        depth: $0.depth
                    )
                }
        )
        let hasMore = candidates.count > effectiveLimit
        let items = Array(candidates.prefix(effectiveLimit))
        let afterGeneration = try CursorGeneration.compose([
            content.chapterListCursorGenerationComponent(),
        ])
        let nextCursor = try session.nextCursor(
            after: afterGeneration,
            hasMore: hasMore,
            locator: hasMore ? try items.last.map { try CursorLocator(words: [UInt64($0.chapterOrder)]) } : nil
        )
        return SemanticChapterListPage(
            bookLocalPK: target.localPK,
            bookAssetID: target.assetID,
            items: items,
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    private func semanticChapterPage(
        target: BookResourceTarget,
        selector: ContentBookSelector,
        chapterOrder: Int,
        maximumCharacters: Int?,
        cursor: String?
    ) throws -> SemanticChapterContinuationPage {
        guard chapterOrder > 0 else { throw BookContentError.chapterNotFound }
        guard target.path != nil else { throw ContentError.bookPathUnavailable }
        let limits = try ChapterContinuationPolicy.limits(maximumCharacters: maximumCharacters)
        let selected = try EPUBSourceResolver.resolve(
            for: target,
            configuration: try requiredConfiguration()
        ).requireReader()
        let content = try BookContent(reader: selected.reader)
        let chapter = try content.resolveChapter(order: chapterOrder)
        let beforeGeneration = try CursorGeneration.compose([
            content.chapterCursorGenerationComponent(for: chapter),
        ])
        let fingerprint = try chapterPageFingerprint(selector: selector, chapterOrder: chapterOrder)
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )
        let offset = try chapterPageOffset(from: session.locator)
        let slice = try content.continuationPage(
            chapter: chapter,
            offset: offset,
            maximumGraphemes: limits.characters,
            maximumUTF8Bytes: limits.utf8Bytes
        )
        let afterGeneration = try CursorGeneration.compose([
            content.chapterCursorGenerationComponent(for: chapter),
        ])
        let nextCursor: String?
        if slice.hasMore {
            guard slice.returnedGraphemes > 0,
                  offset <= Int.max - slice.returnedGraphemes else {
                throw CursorPaginationError.internalContractFailure
            }
            nextCursor = try session.nextCursor(
                after: afterGeneration,
                hasMore: true,
                locator: try CursorLocator(words: [UInt64(offset + slice.returnedGraphemes)])
            )
        } else {
            nextCursor = try session.nextCursor(
                after: afterGeneration,
                hasMore: false,
                locator: nil
            )
        }
        return SemanticChapterContinuationPage(
            bookLocalPK: target.localPK,
            bookAssetID: target.assetID,
            chapterOrder: chapterOrder,
            content: slice.content,
            hasMore: slice.hasMore,
            nextCursor: nextCursor
        )
    }

    private func chapterListFingerprint(selector: ContentBookSelector) throws -> CursorQueryFingerprint {
        try CursorQueryFingerprint.make(
            kind: "content.chapters",
            fields: [CursorFingerprintField("order.version", .unsigned(1))] + contentBookFingerprintFields(selector)
        )
    }

    private func chapterPageFingerprint(
        selector: ContentBookSelector,
        chapterOrder: Int
    ) throws -> CursorQueryFingerprint {
        try CursorQueryFingerprint.make(
            kind: "content.chapter",
            fields: [
                CursorFingerprintField("order.version", .unsigned(1)),
                CursorFingerprintField("chapter.order", .signed(Int64(chapterOrder))),
            ] + contentBookFingerprintFields(selector)
        )
    }

    private func contentBookFingerprintFields(_ selector: ContentBookSelector) -> [CursorFingerprintField] {
        switch selector {
        case let .assetID(assetID):
            [
                CursorFingerprintField("book.kind", .string("asset")),
                CursorFingerprintField("book.value", .string(assetID)),
            ]
        case let .localPK(localPK):
            [
                CursorFingerprintField("book.kind", .string("pk")),
                CursorFingerprintField("book.value", .signed(localPK)),
            ]
        }
    }

    private func chapterListOrder(from locator: CursorLocator?) throws -> Int? {
        guard let locator else { return nil }
        guard locator.words.count == 1,
              locator.words[0] > 0,
              locator.words[0] <= UInt64(Int.max) else {
            throw CursorPaginationError.invalidCursor
        }
        return Int(locator.words[0])
    }

    private func chapterPageOffset(from locator: CursorLocator?) throws -> Int {
        guard let locator else { return 0 }
        guard locator.words.count == 1, locator.words[0] <= UInt64(Int.max) else {
            throw CursorPaginationError.invalidCursor
        }
        return Int(locator.words[0])
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

    package func semanticAnnotationContextResult(
        localPK: Int64,
        charsBefore: Int = 300,
        charsAfter: Int = 300
    ) throws -> SemanticAnnotationContextResult? {
        guard (0...2_000).contains(charsBefore), (0...2_000).contains(charsAfter) else {
            throw AnnotationContextError.invalidWindow
        }
        guard let target = try requiredAnnotationQueries().contextTarget(localPK: localPK) else { return nil }
        return try semanticAnnotationContextResult(
            target: target,
            charsBefore: charsBefore,
            charsAfter: charsAfter
        )
    }

    package func semanticAnnotationContextResult(
        uuid: String,
        charsBefore: Int = 300,
        charsAfter: Int = 300
    ) throws -> SemanticAnnotationContextResult? {
        guard (0...2_000).contains(charsBefore), (0...2_000).contains(charsAfter) else {
            throw AnnotationContextError.invalidWindow
        }
        guard let target = try requiredAnnotationQueries().contextTarget(uuid: uuid) else { return nil }
        return try semanticAnnotationContextResult(
            target: target,
            charsBefore: charsBefore,
            charsAfter: charsAfter
        )
    }

    private func semanticAnnotationContextResult(
        target annotation: AnnotationContextTarget,
        charsBefore: Int,
        charsAfter: Int
    ) throws -> SemanticAnnotationContextResult {
        guard let assetID = annotation.rawAssetID else {
            throw AnnotationContextError.assetIdentityUnavailable
        }
        guard let chapterID = annotation.chapterID else {
            throw AnnotationContextError.chapterUnavailable
        }
        let bookTarget: BookResourceTarget
        do {
            guard let resolved = try requiredBookQueries().uniqueResourceTarget(assetID: assetID) else {
                throw AnnotationContextError.currentBookUnavailable
            }
            bookTarget = resolved
        } catch StableIdentityError.ambiguousBookAssetID {
            throw AnnotationContextError.currentBookAmbiguous
        }
        guard bookTarget.path != nil else {
            throw AnnotationContextError.contentPathUnavailable
        }

        let content = try BookContent(
            reader: EPUBSourceResolver.reader(for: bookTarget, configuration: try requiredConfiguration())
        )
        let chapterText: String
        do {
            chapterText = try content.getChapter(chapterID)
        } catch BookContentError.chapterNotFound {
            throw AnnotationContextError.chapterUnavailable
        }
        let context = try AnnotationContextMatcher.match(
            chapterText: chapterText,
            anchor: annotation.anchor,
            charsBefore: charsBefore,
            charsAfter: charsAfter
        )
        return SemanticAnnotationContextResult(
            annotationLocalPK: annotation.localPK,
            annotationUUID: annotation.uuid,
            context: context
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

    public func annotations(
        matchingNote text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().searchNote(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func annotations(
        matchingText text: String,
        colorName: String? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().searchText(text, colorName: colorName, limit: limit, offset: offset)
    }

    public func recentlyCreatedAnnotations(limit: Int? = 10, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().recentlyCreated(limit: limit, offset: offset)
    }

    public func recentlyModifiedAnnotations() throws -> [EnrichedAnnotation] {
        try requiredAnnotationQueries().recentlyModified()
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

    package func semanticBookmarkedReadingPosition(
        bookAssetID assetID: String
    ) throws -> SemanticBookmarkedReadingPositionResolution {
        let queries = try requiredBookQueries()
        guard let target = try queries.uniqueResourceTarget(assetID: assetID) else {
            return .bookMissing
        }
        return try semanticBookmarkedReadingPosition(target: target, annotationAssetID: assetID)
    }

    package func semanticBookmarkedReadingPosition(
        bookLocalPK localPK: Int64
    ) throws -> SemanticBookmarkedReadingPositionResolution {
        let queries = try requiredBookQueries()
        guard let target = try queries.resourceTarget(localPK: localPK) else {
            return .bookMissing
        }
        guard let annotationAssetID = try queries.annotationAssetID(localPK: localPK) else {
            return .unavailable
        }
        return try semanticBookmarkedReadingPosition(target: target, annotationAssetID: annotationAssetID)
    }

    private func semanticBookmarkedReadingPosition(
        target: BookResourceTarget,
        annotationAssetID: String
    ) throws -> SemanticBookmarkedReadingPositionResolution {
        guard target.path != nil,
              let bookmark = try requiredReadingQueries().semanticCurrentLocation(rawAssetID: annotationAssetID),
              let chapterID = bookmark.chapterID else {
            return .unavailable
        }
        let selected = try EPUBSourceResolver.resolve(
            for: target,
            configuration: try requiredConfiguration()
        ).requireReader()
        let content = try BookContent(reader: selected.reader)
        let chapters = try content.listChapters()
        guard let chapter = chapters.first(where: { $0.id == chapterID }) else {
            return .unavailable
        }
        return .position(SemanticBookmarkedReadingPosition(
            bookLocalPK: target.localPK,
            bookAssetID: target.assetID,
            chapterOrder: chapter.order,
            title: chapter.title,
            totalChapters: chapters.count
        ))
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
