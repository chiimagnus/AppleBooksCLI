import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ExportServiceTests")
struct ExportServiceTests {
    @Test
    func bulkEPUBExportDoesNotRequirePDFWorkerOrReadEPUBContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missingEPUB = fixture.root.appendingPathComponent("missing.epub", isDirectory: true)
        try fixture.createLibrary([
            .init(pk: 1, assetID: "epub-current", title: "Current EPUB", contentType: 1, path: missingEPUB.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "epub-current", selectedText: "quote"),
        ])

        let bundle = try fixture.service().makeBundle(options: ExportOptions(source: .epub))

        #expect(bundle.groups.count == 1)
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.statistics.epubAnnotationCount == 1)
        #expect(bundle.statistics.pdfHighlightCount == 0)
        #expect(bundle.warnings.isEmpty)
        guard case let .epubCurrent(book) = bundle.groups[0].source else {
            Issue.record("expected current EPUB group")
            return
        }
        #expect(book.assetID == "epub-current")
    }

    @Test
    func userScopeExcludesSystemRowsBeforeSelectionAndCountsOverlappingPresence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "presence", selectedText: "quote", note: "note"),
            .init(pk: 2, assetID: "presence", selectedText: nil, note: "note"),
            .init(pk: 3, assetID: "presence", selectedText: "quote"),
            .init(pk: 4, assetID: "presence", selectedText: " \t\r\n", note: " \t\r\n"),
            .init(pk: 5, assetID: "presence", selectedText: "system text", note: "system note", type: 3),
        ])
        let service = try fixture.service()
        for selectors: [ExportBookSelector] in [[], [.assetID("presence")]] {
            let bundle = try service.makeBundle(options: ExportOptions(bookSelectors: selectors))
            #expect(bundle.sourceTotals.epubAnnotationCount == 4)
            #expect(bundle.statistics.recordCount == 3)
            #expect(bundle.statistics.highlightCount == 2)
            #expect(bundle.statistics.noteCount == 2)
            let artifact = String(decoding: try JSONExporter.render(bundle, exportedAt: Date(timeIntervalSince1970: 0)), as: UTF8.self)
            #expect(!artifact.contains("system text"))
            #expect(!artifact.contains("system note"))
            #expect(!artifact.contains("bookmarkCount"))
        }
    }

    @Test
    func archivalExportPreservesLargeAnnotationTextWithoutOrdinaryQueryBudgets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = String(repeating: "archive", count: 150_000)
        try fixture.createLibrary([
            .init(pk: 1, assetID: "archive-book", title: "Archive", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "archive-book", selectedText: body, note: body),
        ])

        let bundle = try fixture.service().makeBundle(options: ExportOptions())
        let record = try #require(bundle.groups.first?.records.first)
        guard case let .epub(enriched) = record.payload else {
            Issue.record("expected EPUB record")
            return
        }
        #expect(enriched.annotation.selectedText == body)
        #expect(enriched.annotation.note == body)

        let data = try JSONExporter.render(bundle, exportedAt: Date(timeIntervalSince1970: 0))
        #expect(data.count > body.utf8.count * 2)
    }

    @Test
    func allSourceMergesCanonicalEPUBAndPDFAndKeepsFailuresAsWarnings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let goodPDF = try fixture.pdf(name: "good.pdf")
        _ = try fixture.pdf(name: "bad.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "epub-current", title: "Current EPUB", contentType: 1, path: nil),
            .init(pk: 2, assetID: "pdf-current", title: "Current PDF", contentType: 3, path: goodPDF.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "epub-current", selectedText: "epub"),
            .init(pk: 2, assetID: "pdf-current", selectedText: "must be excluded"),
            .init(pk: 3, assetID: "historical", selectedText: "history"),
            .init(pk: 4, assetID: "unmapped", selectedText: "orphan"),
        ])
        try fixture.createConfiguration(historical: [
            "historical": (title: "Historical", author: "Archive Author"),
        ])
        let worker = try fixture.worker()

        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(source: .all)
        )

        #expect(bundle.sourceTotals.epubDocumentCount == 3)
        #expect(bundle.sourceTotals.epubAnnotationCount == 3)
        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 2)
        #expect(bundle.sourceTotals.pdfSucceededDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfFailedDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfHighlightCount == 1)

        #expect(bundle.statistics.documentCount == 4)
        #expect(bundle.statistics.epubDocumentCount == 3)
        #expect(bundle.statistics.pdfDocumentCount == 1)
        #expect(bundle.statistics.recordCount == 4)
        #expect(bundle.statistics.epubAnnotationCount == 3)
        #expect(bundle.statistics.pdfHighlightCount == 1)
        #expect(bundle.statistics.highlightCount == 4)
        #expect(bundle.statistics.noteCount == 0)
        #expect(bundle.statistics.historicalEPUBAnnotationCount == 1)
        #expect(bundle.statistics.unmappedEPUBAnnotationCount == 1)
        #expect(bundle.warnings.count == 1)
        guard case let .pdfFailure(failure) = try #require(bundle.warnings.first) else {
            Issue.record("expected PDF failure warning")
            return
        }
        #expect(failure.source.fileURL.lastPathComponent == "bad.pdf")
        #expect(failure.reason == .worker(.workerFailure(.unreadableDocument)))

        let epubPKs = bundle.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(Set(epubPKs) == [1, 3, 4])
        #expect(epubPKs.contains(2) == false)
        let pdfRecord = try #require(bundle.groups.flatMap(\.records).first { record in
            if case .pdf = record.payload { return true }
            return false
        })
        guard case let .pdf(source, highlight) = pdfRecord.payload else {
            Issue.record("expected PDF record")
            return
        }
        #expect(source.book?.assetID == "pdf-current")
        #expect(highlight.page == 2)
        #expect(highlight.text == "pdf text")
    }

    @Test
    func pdfSourceSelectorFiltersInventoryBeforeWorkerInvocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try fixture.pdf(name: "selected.pdf")
        _ = try fixture.pdf(name: "unselected-bad.pdf")
        try fixture.createLibrary([])
        try fixture.createAnnotations([])
        let worker = try fixture.worker()

        let service = try fixture.service(worker: worker)
        let sourceID = try #require(service.pdfService).sourceResolver.inventoryPage(bookQueries: service.bookQueries)
            .items.first { $0.title == "selected" }?.pdfSourceID
        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(
                bookSelectors: [.pdfSourceID(try #require(sourceID))]
            )
        )

        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfSucceededDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfFailedDocumentCount == 0)
        #expect(bundle.statistics.pdfDocumentCount == 1)
        #expect(bundle.warnings.isEmpty)
        #expect(try fixture.workerCallCount() == 1)
        guard case let .pdf(source) = try #require(bundle.groups.first).source else {
            Issue.record("expected PDF group")
            return
        }
        #expect(source.fileURL == selected)
    }

    @Test
    func documentIdentityMergesUnknownSourceSortsCanonicallyAndRejectsDigestCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "z-book", title: "Same", contentType: 1, path: nil),
            .init(pk: 2, assetID: "a-book", title: "Same", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "z-book", selectedText: "z"),
            .init(pk: 2, assetID: "a-book", selectedText: "a"),
            .init(pk: 3, assetID: nil, selectedText: "unknown-one"),
            .init(pk: 4, assetID: nil, selectedText: "unknown-two"),
        ])

        let service = try fixture.service()
        let forward = try service.makeBundle(options: ExportOptions(
            bookSelectors: [.assetID("z-book"), .assetID("a-book")]
        ))
        let reverse = try service.makeBundle(options: ExportOptions(
            bookSelectors: [.assetID("a-book"), .assetID("z-book")]
        ))
        #expect(forward.groups.map(\.documentIdentity) == reverse.groups.map(\.documentIdentity))
        #expect(forward.groups.allSatisfy { $0.documentIdentity?.fullKey.hasPrefix("doc1_") == true })

        let bulk = try service.makeBundle(options: ExportOptions(source: .epub))
        let unknown = try #require(bulk.groups.first { group in
            if case .epubUnmapped(assetID: nil) = group.source { return true }
            return false
        })
        #expect(unknown.records.count == 2)
        #expect(bulk.groups.count == 3)

        var colliding = service
        colliding.documentIdentityDigest = { _ in Array(repeating: 0, count: 32) }
        #expect(throws: ExportServiceError.documentIdentityCollision) {
            _ = try colliding.makeBundle(options: ExportOptions(source: .epub))
        }
    }

    @Test
    func statisticsUseFinalSelectionWhileSourceTotalsRemainPreFilter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "archive", selectedText: "first highlight"),
            .init(pk: 2, assetID: "archive", selectedText: "quote", note: "note"),
            .init(pk: 3, assetID: "archive", selectedText: "second highlight"),
        ])

        let bundle = try fixture.service().makeBundle(
            options: ExportOptions(
                hasHighlight: true,
                hasNote: false
            )
        )

        #expect(bundle.sourceTotals.epubAnnotationCount == 3)
        #expect(bundle.sourceTotals.epubDocumentCount == 1)
        #expect(bundle.statistics.recordCount == 2)
        #expect(bundle.statistics.highlightCount == 2)
        #expect(bundle.statistics.noteCount == 0)
        let selected = bundle.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(selected == [1, 3])
    }

    @Test
    func defaultReadingOrderSharesChapterMappingAndFallbackWithAnnotationQueries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let epub = try fixture.epub(name: "ordered.epub")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "ordered", title: "Ordered", contentType: 1, path: epub.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "ordered", selectedText: "second chapter", cfi: "epubcfi(/6/2[other]!/4/2:1)"),
            .init(pk: 2, assetID: "ordered", selectedText: "first chapter", cfi: "epubcfi(/6/10[chapter]!/4/2:1)"),
            .init(pk: 3, assetID: "ordered", selectedText: "no location", cfi: "invalid"),
        ])
        let service = try fixture.service()
        let options = try ExportOptions(bookSelectors: [.assetID("ordered")])
        let mapped = try service.makeBundle(options: options)
        let mappedPKs = mapped.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(mappedPKs == [2, 1, 3])
        let page = try #require(service.annotationQueries).semanticPage(AnnotationQueryRequest(
            book: .assetID("ordered"), order: .reading
        ))
        #expect(mappedPKs == page.items.map(\.localPK))
        let markdown = MarkdownAnnotationExporter.render(mapped)
        #expect(try #require(markdown.range(of: "first chapter")).lowerBound < #require(markdown.range(of: "second chapter")).lowerBound)

        try FileManager.default.removeItem(at: epub)
        let fallback = try service.makeBundle(options: options)
        let fallbackPKs = fallback.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(fallbackPKs == [1, 2, 3])
        let unavailablePage = try #require(service.annotationQueries).semanticPage(AnnotationQueryRequest(
            book: .assetID("ordered"), order: .reading
        ))
        #expect(fallbackPKs == unavailablePage.items.map(\.localPK))
    }

    @Test
    func localPKSelectorUsesExactCurrentBookIdentityWithoutNumericGuessing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 123, assetID: "stable-123", title: "PK Book", contentType: 1, path: nil),
            .init(pk: 1, assetID: "123", title: "Numeric Asset", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "stable-123", selectedText: "pk quote"),
            .init(pk: 2, assetID: "123", selectedText: "asset quote"),
        ])

        let byPK = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.localPK(123)], hasHighlight: true)
        )
        let byAsset = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.assetID("123")], hasHighlight: true)
        )

        let pkRows = byPK.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        let assetRows = byAsset.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(pkRows == [1])
        #expect(assetRows == [2])
    }

    @Test
    func stableAssetSelectorStillReachesHistoricalRowsWithoutCurrentBook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "historical", selectedText: "history quote"),
        ])
        try fixture.createConfiguration(historical: [
            "historical": (title: "History", author: "Archive Author"),
        ])

        let bundle = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.assetID("historical")], hasHighlight: true)
        )

        #expect(bundle.statistics.recordCount == 1)
        guard case let .epubHistorical(assetID, metadata) = try #require(bundle.groups.first).source else {
            Issue.record("expected historical EPUB group")
            return
        }
        #expect(assetID == "historical")
        #expect(metadata.title == "History")
    }

    @Test
    func archivePDFExportTraversesEveryWorkerPage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "paged.pdf")
        try fixture.createLibrary([])
        try fixture.createAnnotations([])
        let worker = try fixture.pagedWorker()

        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(source: .pdf)
        )

        #expect(bundle.groups.count == 1)
        #expect(bundle.groups[0].records.count == 2)
        #expect(bundle.statistics.pdfHighlightCount == 2)
        #expect(bundle.sourceTotals.pdfHighlightCount == 2)
        #expect(bundle.warnings.isEmpty)
        #expect(try fixture.workerCallCount() == 2)
    }

    @Test
    func oversizedArchiveWorkerEnvelopeBecomesWarningWithoutPartialExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "oversized.pdf")
        try fixture.createLibrary([])
        try fixture.createAnnotations([])
        let worker = try fixture.oversizeWorker()

        let bundle = try fixture.service(worker: worker, timeout: 10).makeBundle(
            options: ExportOptions(source: .pdf)
        )

        #expect(bundle.groups.isEmpty)
        #expect(bundle.statistics.pdfHighlightCount == 0)
        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfSucceededDocumentCount == 0)
        #expect(bundle.sourceTotals.pdfFailedDocumentCount == 1)
        let warning = try #require(bundle.warnings.first)
        guard case let .pdfFailure(failure) = warning else {
            Issue.record("Expected PDF failure warning")
            return
        }
        #expect(failure.reason == .worker(.stdoutLimitExceeded(capturedBytes: PDFWorkerClient.stdoutLimit)))
    }

    @Test
    func missingStableSelectorFailsBeforeWorker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "unrelated.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "present", title: "Present", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "present", selectedText: "quote"),
        ])
        let worker = try fixture.worker()

        #expect(throws: ExportServiceError.selectorNotFound) {
            _ = try fixture.service(worker: worker).makeBundle(
                options: ExportOptions(bookSelectors: [.assetID("missing")])
            )
        }
        #expect(try fixture.workerCallCount() == 0)
    }

    @Test
    func assetSelectorUsesExactStableIdentityAndAmbiguityFailsBeforeWorker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "unrelated.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "duplicate", title: "One", contentType: 1, path: nil),
            .init(pk: 2, assetID: "duplicate", title: "Two", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "duplicate", selectedText: "quote"),
        ])
        let worker = try fixture.worker()

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.service(worker: worker).makeBundle(
                options: ExportOptions(
                    source: .all,
                    bookSelectors: [.assetID("duplicate")]
                )
            )
        }
        #expect(try fixture.workerCallCount() == 0)
    }

    @Test
    func exactEvidenceAndDuplicateSelectorsUseOneSourceOwner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "current", title: "Current", contentType: 1, path: nil),
            .init(pk: 2, assetID: "empty", title: "Empty", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "current", selectedText: "quote"),
            .init(pk: 2, assetID: "system", selectedText: "system", type: 3),
            .init(pk: 3, assetID: "unmapped", selectedText: "orphan"),
        ])
        try fixture.createConfiguration(historical: ["history": (title: "History", author: "Author")])
        let service = try fixture.service()
        let resolver = ExportSourceResolver(bookQueries: service.bookQueries, pdfSourceResolver: service.pdfSourceResolver)
        for selectors: [ExportBookSelector] in [
            [.assetID("current"), .localPK(1), .assetID("current")],
            [.localPK(1), .assetID("current")],
        ] {
            #expect(try resolver.resolve(selectors).map(\.key) == [.currentBook(1)])
            #expect(try service.makeBundle(options: ExportOptions(bookSelectors: selectors)).statistics.recordCount == 1)
        }
        for selectors: [ExportBookSelector] in [
            [.assetID("current"), .assetID("typo")], [.assetID("system")], [.localPK(999)],
        ] {
            #expect(throws: ExportServiceError.selectorNotFound) {
                _ = try service.makeBundle(options: ExportOptions(bookSelectors: selectors))
            }
        }
        for assetID in ["empty", "history"] {
            let bundle = try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID(assetID)]))
            #expect(bundle.statistics.recordCount == 0)
            #expect(bundle.complete)
        }
        #expect(try resolver.resolve([.assetID("unmapped")]).map(\.key) == [.epubAsset("unmapped")])
        #expect(try resolver.resolve([.assetID("\u{e9}"), .assetID("e\u{301}")]).count == 2)
        #expect(try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID("unmapped")])).statistics.recordCount == 1)
    }

    @Test
    func exactPDFSlotsDeduplicateAndUnavailableSourcesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = try fixture.pdf(name: "shared.pdf")
        let ordinary = try fixture.pdf(name: "ordinary.pdf")
        let fallback = try fixture.pdf(name: "fallback.pdf")
        let bad = try fixture.pdf(name: "bad.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "shared-one", title: "Shared One", contentType: 3, path: shared.path),
            .init(pk: 2, assetID: "shared-two", title: "Shared Two", contentType: 3, path: shared.path),
            .init(pk: 3, assetID: "ordinary", title: "Ordinary", contentType: 3, path: ordinary.path),
            .init(pk: 4, assetID: "unreadable", title: "Unreadable", contentType: 3, path: bad.path),
        ])
        try fixture.createAnnotations([])
        let service = try fixture.service(worker: fixture.worker())
        let pdfResolver = try #require(service.pdfService).sourceResolver
        let resolver = ExportSourceResolver(bookQueries: service.bookQueries, pdfSourceResolver: pdfResolver)
        let items = try pdfResolver.inventoryPage(bookQueries: service.bookQueries).items
        let sharedID = try #require(items.first { $0.title == "shared" }?.pdfSourceID)
        let fallbackID = try #require(items.first { $0.title == "fallback" }?.pdfSourceID)
        for selectors: [ExportBookSelector] in [
            [.assetID("shared-one"), .localPK(2), .pdfSourceID(sharedID), .pdfSourceID(sharedID)],
            [.pdfSourceID(sharedID), .localPK(1), .assetID("shared-two")],
            [.assetID("ordinary"), .localPK(3)],
            [.pdfSourceID(fallbackID), .pdfSourceID(fallbackID)],
        ] {
            let resolved = try resolver.resolve(selectors)
            #expect(resolved.count == 1)
            let source = try #require(resolved.first?.pdfSource)
            if let sourceID = source.pdfSourceID {
                #expect(resolved.first?.key == .pdfSourceID(sourceID))
            } else {
                #expect(resolved.first?.key == .pdfBookAsset(try #require(source.book?.assetID ?? source.bookSummary?.assetID)))
            }
            let before = try fixture.workerCallCount()
            let bundle = try service.makeBundle(options: ExportOptions(bookSelectors: selectors))
            #expect(bundle.statistics.recordCount == 1)
            #expect(bundle.statistics.documentCount == 1)
            #expect(try fixture.workerCallCount() == before + 1)
        }
        for options in [
            try ExportOptions(bookSelectors: [.assetID("ordinary")], hasHighlight: false),
            try ExportOptions(bookSelectors: [.assetID("ordinary")], underline: true),
            try ExportOptions(bookSelectors: [.assetID("ordinary")], hasNote: true),
        ] {
            #expect(try service.makeBundle(options: options).statistics.recordCount == 0)
        }
        #expect(throws: ExportServiceError.pdfReadFailed) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID("unreadable")]))
        }
        #expect(throws: ExportServiceError.pdfWorkerUnavailable) {
            _ = try fixture.service().makeBundle(options: ExportOptions(bookSelectors: [.assetID("ordinary")]))
        }
        try FileManager.default.removeItem(at: ordinary)
        #expect(throws: ExportServiceError.pdfSourceUnavailable) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID("ordinary")]))
        }
        try FileManager.default.removeItem(at: fallback)
        #expect(throws: ExportServiceError.selectorNotFound) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.pdfSourceID(fallbackID)]))
        }
        let missingID = "pdf1_" + String(repeating: "f", count: 64)
        #expect(throws: ExportServiceError.selectorNotFound) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.pdfSourceID(missingID)]))
        }
    }

    @Test
    func bulkAllWithoutWorkerIsExplicitlyIncomplete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([.init(pk: 1, assetID: "orphan", selectedText: "quote")])
        let bundle = try fixture.service().makeBundle(options: ExportOptions())
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.warnings == [.pdfUnavailable])
        #expect(!bundle.complete)
    }

    @Test
    func ambiguousOpaquePDFIdentityFailsBeforeWorker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "one.pdf")
        _ = try fixture.pdf(name: "two.pdf")
        try fixture.createLibrary([])
        try fixture.createAnnotations([])
        let existing = try fixture.service(worker: fixture.worker())
        let pdfResolver = PDFSourceResolver(fallbackRoot: fixture.pdfRoot, sourceIDDigest: { _ in
            Array(repeating: 0, count: 32)
        })
        let service = ExportService(
            annotationQueries: existing.annotationQueries, bookQueries: existing.bookQueries,
            configuration: existing.configuration,
            pdfService: PDFHighlightService(
                bookQueries: existing.bookQueries, sourceResolver: pdfResolver,
                workerClient: try #require(existing.pdfService).workerClient
            )
        )
        #expect(throws: PDFInventoryError.ambiguousSourceID) {
            _ = try service.makeBundle(options: ExportOptions(
                bookSelectors: [.pdfSourceID("pdf1_" + String(repeating: "0", count: 64))]
            ))
        }
        #expect(try fixture.workerCallCount() == 0)
    }

    private final class Fixture {
        static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let root: URL
        let pdfRoot: URL
        let libraryURL: URL
        let annotationsURL: URL
        let configurationURL: URL
        let counterURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            pdfRoot = root.appendingPathComponent("pdfs", isDirectory: true)
            libraryURL = root.appendingPathComponent("library.sqlite")
            annotationsURL = root.appendingPathComponent("annotations.sqlite")
            configurationURL = root.appendingPathComponent("config.json")
            counterURL = root.appendingPathComponent("worker-calls.txt")
            try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
            try createConfiguration()
        }

        func createLibrary(_ rows: [BookRow]) throws {
            var values: [String] = []
            for row in rows {
                values.append("(\(row.pk),\(sql(row.assetID)),\(sql(row.title)),\(row.contentType.map(String.init) ?? "NULL"),\(sql(row.path)))")
            }
            var sql = """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZCONTENTTYPE INTEGER,
              ZPATH TEXT
            );
            """
            if values.isEmpty == false {
                sql += "INSERT INTO ZBKLIBRARYASSET VALUES " + values.joined(separator: ",") + ";"
            }
            try createDatabase(libraryURL, sql: sql)
        }

        func createAnnotations(_ rows: [AnnotationRow]) throws {
            var values: [String] = []
            for row in rows {
                values.append("(\(row.pk),0,\(row.type.map(String.init) ?? "NULL"),\(sql(row.assetID)),\(sql(row.selectedText)),NULL,\(sql(row.note)),\(row.style.map(String.init) ?? "NULL"),\(row.underline.map { $0 ? "1" : "0" } ?? "NULL"),\(sql(row.cfi)),NULL)")
            }
            var sql = """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZANNOTATIONREPRESENTATIVETEXT TEXT,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONSTYLE INTEGER,
              ZANNOTATIONISUNDERLINE INTEGER,
              ZANNOTATIONLOCATION TEXT,
              ZANNOTATIONCREATIONDATE REAL
            );
            """
            if values.isEmpty == false {
                sql += "INSERT INTO ZAEANNOTATION VALUES " + values.joined(separator: ",") + ";"
            }
            try createDatabase(annotationsURL, sql: sql)
        }

        func createConfiguration(historical: [String: (title: String, author: String)] = [:]) throws {
            let entries = historical.mapValues { ["title": $0.title, "author": $0.author] }
            let data = try JSONSerialization.data(withJSONObject: ["historical_assets": entries])
            try data.write(to: configurationURL)
        }

        func pdf(name: String) throws -> URL {
            let url = pdfRoot.appendingPathComponent(name).standardizedFileURL
            try Data("synthetic pdf".utf8).write(to: url)
            return url.resolvingSymlinksInPath()
        }

        func epub(name: String) throws -> URL {
            let epub = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("""
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata>
                <dc:title>EPUB Enriched</dc:title>
                <dc:publisher>Publisher</dc:publisher>
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="other" href="other.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/><itemref idref="other"/></spine>
            </package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>chapter</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            try Data("<html><body>other</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/other.xhtml"))
            try Self.png.write(to: epub.appendingPathComponent("OPS/cover.png"))
            return epub.standardizedFileURL.resolvingSymlinksInPath()
        }

        func worker() throws -> URL {
            let worker = root.appendingPathComponent("fake-worker")
            let counter = shellQuote(counterURL.path)
            let script = """
            #!/bin/sh
            set -eu
            printf 'x' >> \(counter)
            IFS= read -r request || true
            case "$request" in
              *bad.pdf*|*unselected-bad.pdf*)
                printf '%s' '{"version":2,"status":"failure","errorCode":"unreadableDocument"}'
                ;;
              *)
                printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":2,"traversalIndex":3,"bounds":{"x":1,"y":2,"width":30,"height":4},"quadrilateralPoints":[],"note":null,"pdfKitRGBA":[1,1,0,1],"presentationColor":{"color":"yellow","distance":0,"isApproximate":true},"text":"pdf text","textSource":"quadSelection","textIsApproximate":true}],"hasMore":false,"generation":"pdfg2_0000000000000000000000000000000000000000000000000000000000000000"}'
                ;;
            esac
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
            return worker
        }

        func pagedWorker() throws -> URL {
            let worker = root.appendingPathComponent("paged-worker")
            let counter = shellQuote(counterURL.path)
            let generation = "pdfg2_" + String(repeating: "0", count: 64)
            let script = """
            #!/bin/sh
            set -eu
            printf 'x' >> \(counter)
            calls=$(wc -c < \(counter) | tr -d ' ')
            IFS= read -r request || true
            if [ "$calls" -eq 1 ]; then
              printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"note":"first","textIsApproximate":true}],"nextTraversal":{"pageIndex":0,"annotationIndex":1},"hasMore":true,"generation":"\(generation)"}'
            else
              printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":2,"traversalIndex":1,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"note":"second","textIsApproximate":true}],"hasMore":false,"generation":"\(generation)"}'
            fi
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
            return worker
        }

        func oversizeWorker() throws -> URL {
            let worker = root.appendingPathComponent("oversize-worker")
            let chunk = shellQuote(String(repeating: "x", count: 4_096))
            let script = """
            #!/bin/sh
            set -eu
            IFS= read -r request || true
            chunk=\(chunk)
            while :; do printf '%s' "$chunk"; done
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
            return worker
        }

        func workerCallCount() throws -> Int {
            guard FileManager.default.fileExists(atPath: counterURL.path) else { return 0 }
            return try String(contentsOf: counterURL, encoding: .utf8).count
        }

        func service(worker: URL? = nil, timeout: TimeInterval = 2) throws -> ExportService {
            let libraryConnection = try SQLiteConnection.readOnly(path: libraryURL.path)
            let bookQueries = BookQueries(connection: libraryConnection)
            let configuration = try AppleBooksConfiguration(fileURL: configurationURL)
            let annotationQueries = AnnotationQueries(
                annotationConnection: try SQLiteConnection.readOnly(path: annotationsURL.path),
                bookQueries: bookQueries,
                historicalAssets: configuration.historicalAssets
            )
            let pdfService = worker.map {
                PDFHighlightService(
                    bookQueries: bookQueries,
                    sourceResolver: PDFSourceResolver(fallbackRoot: pdfRoot),
                    workerClient: PDFWorkerClient(workerURL: $0, timeout: timeout, terminationGrace: 0.05)
                )
            }
            return ExportService(
                annotationQueries: annotationQueries,
                bookQueries: bookQueries,
                configuration: configuration,
                pdfService: pdfService
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        private func sql(_ value: String?) -> String {
            guard let value else { return "NULL" }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        private func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private struct BookRow {
        let pk: Int64
        let assetID: String?
        let title: String?
        let contentType: Int64?
        let path: String?
    }

    private struct AnnotationRow {
        let pk: Int64
        let assetID: String?
        let selectedText: String?
        let note: String?
        let type: Int64?
        let style: Int64?
        let underline: Bool?
        let cfi: String?

        init(
            pk: Int64,
            assetID: String?,
            selectedText: String?,
            note: String? = nil,
            type: Int64? = 1,
            style: Int64? = nil,
            underline: Bool? = nil,
            cfi: String? = nil
        ) {
            self.pk = pk
            self.assetID = assetID
            self.selectedText = selectedText
            self.note = note
            self.type = type
            self.style = style
            self.underline = underline
            self.cfi = cfi
        }
    }

    private enum FixtureError: Error {
        case database
        case permissions
    }
}
