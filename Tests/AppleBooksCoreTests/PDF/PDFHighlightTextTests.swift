import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AppleBooksCore

@Suite("PDFHighlightTextTests")
struct PDFHighlightTextTests {
    @Test
    func quadSelectionRecoversEnglishCJKAndRepeatedTextUsingPageGeometry() throws {
        let fixture = try TextFixture(lines: [
            ("English single line", CGPoint(x: 40, y: 240)),
            ("中文高亮测试", CGPoint(x: 40, y: 200)),
            ("Repeated target", CGPoint(x: 40, y: 150)),
            ("Repeated target", CGPoint(x: 220, y: 150)),
        ])
        defer { fixture.remove() }
        let document = try fixture.document()
        let page = try #require(document.page(at: 0))

        for text in ["English single line", "中文高亮测试"] {
            let rect = try fixture.bounds(of: text, occurrence: 0, in: document, page: page)
            #expect(rect.origin.x > 0 && rect.origin.y > 0)
            let extraction = PDFHighlightTextExtractor().extract(
                page: page,
                annotationBounds: rect,
                quadrilateralPoints: localQuad(for: rect, annotationBounds: rect)
            )
            #expect(extraction.text == text)
            #expect(extraction.source == .quadSelection)
            #expect(extraction.isApproximate)
            #expect(extraction.unavailableReason == nil)
        }

        let repeatedRect = try fixture.bounds(of: "Repeated target", occurrence: 1, in: document, page: page)
        let repeated = PDFHighlightTextExtractor().extract(
            page: page,
            annotationBounds: repeatedRect,
            quadrilateralPoints: localQuad(for: repeatedRect, annotationBounds: repeatedRect)
        )
        #expect(repeated.text == "Repeated target")
        #expect(repeated.source == .quadSelection)
    }

    @Test
    func multipleQuadsPreservePageOrderAndPartialSelections() throws {
        let fixture = try TextFixture(lines: [
            ("First partial tail", CGPoint(x: 40, y: 220)),
            ("Second line end", CGPoint(x: 40, y: 180)),
        ])
        defer { fixture.remove() }
        let document = try fixture.document()
        let page = try #require(document.page(at: 0))
        let first = try fixture.bounds(of: "partial tail", occurrence: 0, in: document, page: page)
        let second = try fixture.bounds(of: "Second line", occurrence: 0, in: document, page: page)
        let annotationBounds = first.union(second)
        let quads = localQuad(for: first, annotationBounds: annotationBounds)
            + localQuad(for: second, annotationBounds: annotationBounds)

        let extraction = PDFHighlightTextExtractor().extract(
            page: page,
            annotationBounds: annotationBounds,
            quadrilateralPoints: quads
        )

        #expect(extraction.text == "partial tail Second line")
        #expect(extraction.source == .quadSelection)
        #expect(extraction.isApproximate)
    }

    @Test
    func missingUsableQuadsFallsBackToBoundsAndEmptySelectionKeepsRawHighlight() throws {
        let fixture = try TextFixture(lines: [("Bounds fallback", CGPoint(x: 60, y: 180))])
        defer { fixture.remove() }
        let document = try fixture.document()
        let page = try #require(document.page(at: 0))
        let bounds = try fixture.bounds(of: "Bounds fallback", occurrence: 0, in: document, page: page)

        let fallback = PDFHighlightTextExtractor().extract(
            page: page,
            annotationBounds: bounds,
            quadrilateralPoints: [CGPoint(x: CGFloat.nan, y: 0), .zero, .zero, .zero]
        )
        #expect(fallback.text == "Bounds fallback")
        #expect(fallback.source == .boundsFallback)
        #expect(fallback.isApproximate)
        #expect(fallback.unavailableReason == nil)

        let unavailable = PDFHighlightTextExtractor().extract(
            page: page,
            annotationBounds: CGRect(x: 300, y: 20, width: 40, height: 20),
            quadrilateralPoints: []
        )
        #expect(unavailable.text == nil)
        #expect(unavailable.source == nil)
        #expect(unavailable.isApproximate)
        #expect(unavailable.unavailableReason == .noTextSelection)
    }

    @Test
    func readerIntegratesLocalQuadCoordinatesWithNonZeroAnnotationOrigin() throws {
        let fixture = try TextFixture(lines: [("Reader integration", CGPoint(x: 80, y: 170))])
        defer { fixture.remove() }
        let document = try fixture.document()
        let page = try #require(document.page(at: 0))
        let bounds = try fixture.bounds(of: "Reader integration", occurrence: 0, in: document, page: page)
        #expect(bounds.origin.x > 0 && bounds.origin.y > 0)

        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = localQuad(for: bounds, annotationBounds: bounds).map { NSValue(point: $0) }
        page.addAnnotation(annotation)
        guard document.write(to: fixture.annotatedURL) else { throw FixtureError.writeFailed }

        let highlight = try #require(try PDFHighlightReader().read(fileURL: fixture.annotatedURL).first)
        #expect(highlight.text == "Reader integration")
        #expect(highlight.textSource == .quadSelection)
        #expect(highlight.textIsApproximate)
        #expect(highlight.textUnavailableReason == nil)
    }

    private func localQuad(for pageRect: CGRect, annotationBounds: CGRect) -> [CGPoint] {
        let minX = pageRect.minX - annotationBounds.minX
        let maxX = pageRect.maxX - annotationBounds.minX
        let minY = pageRect.minY - annotationBounds.minY
        let maxY = pageRect.maxY - annotationBounds.minY
        return [
            CGPoint(x: minX, y: maxY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
        ]
    }

    private final class TextFixture {
        let root: URL
        let baseURL: URL
        let annotatedURL: URL

        init(lines: [(String, CGPoint)]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            baseURL = root.appendingPathComponent("text.pdf")
            annotatedURL = root.appendingPathComponent("annotated.pdf")
            try Self.writePDF(lines: lines, to: baseURL)
        }

        func document() throws -> PDFDocument {
            guard let document = PDFDocument(url: baseURL) else { throw FixtureError.openFailed }
            return document
        }

        func bounds(
            of text: String,
            occurrence: Int,
            in document: PDFDocument,
            page: PDFPage
        ) throws -> CGRect {
            let matches = document.findString(text, withOptions: [])
            guard matches.indices.contains(occurrence) else { throw FixtureError.selectionMissing }
            let bounds = matches[occurrence].bounds(for: page)
            guard bounds.isEmpty == false else { throw FixtureError.selectionMissing }
            return bounds
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func writePDF(lines: [(String, CGPoint)], to url: URL) throws {
            var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                throw FixtureError.writeFailed
            }
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
            for (text, point) in lines {
                NSString(string: text).draw(at: point, withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
        }
    }

    private enum FixtureError: Error {
        case writeFailed
        case openFailed
        case selectionMissing
    }
}
