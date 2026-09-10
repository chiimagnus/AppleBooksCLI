import AppKit
import Foundation
import PDFKit

public enum PDFHighlightReaderError: Error, Equatable, Sendable {
    case unreadableDocument
    case pageUnavailable(Int)
    case invalidTraversal
}

struct PDFHighlightReaderPage: Equatable, Sendable {
    let highlights: [PDFHighlight]
    let nextTraversal: PDFWorkerTraversal?
}

struct PDFHighlightReader {
    func readPage(
        fileURL: URL,
        start: PDFWorkerTraversal?,
        limit: Int
    ) throws -> PDFHighlightReaderPage {
        guard limit > 0, let document = PDFDocument(url: fileURL) else {
            throw PDFHighlightReaderError.unreadableDocument
        }
        return try scan(document: document, start: start, limit: limit)
    }

    private func scan(
        document: PDFDocument,
        start: PDFWorkerTraversal?,
        limit: Int?
    ) throws -> PDFHighlightReaderPage {
        let startPage = start?.pageIndex ?? 0
        guard startPage >= 0, startPage <= document.pageCount else {
            throw PDFHighlightReaderError.invalidTraversal
        }

        var highlights: [PDFHighlight] = []
        if let limit { highlights.reserveCapacity(limit) }
        guard startPage < document.pageCount else {
            return PDFHighlightReaderPage(highlights: [], nextTraversal: nil)
        }

        for pageIndex in startPage..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw PDFHighlightReaderError.pageUnavailable(pageIndex + 1)
            }
            let annotations = page.annotations
            let firstAnnotation = pageIndex == startPage ? (start?.annotationIndex ?? 0) : 0
            guard firstAnnotation >= 0, firstAnnotation <= annotations.count else {
                throw PDFHighlightReaderError.invalidTraversal
            }
            for annotationIndex in firstAnnotation..<annotations.count {
                let annotation = annotations[annotationIndex]
                guard annotation.type == "Highlight" else { continue }
                if let limit, highlights.count == limit {
                    return PDFHighlightReaderPage(
                        highlights: highlights,
                        nextTraversal: PDFWorkerTraversal(
                            pageIndex: pageIndex,
                            annotationIndex: annotationIndex
                        )
                    )
                }
                highlights.append(try highlight(
                    annotation,
                    page: page,
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex
                ))
            }
        }
        return PDFHighlightReaderPage(highlights: highlights, nextTraversal: nil)
    }

    private func highlight(
        _ annotation: PDFAnnotation,
        page: PDFPage,
        pageIndex: Int,
        annotationIndex: Int
    ) throws -> PDFHighlight {
        let quadrilateralPoints = annotation.quadrilateralPoints?.map(\.pointValue) ?? []
        let text = PDFHighlightTextExtractor().extract(
            page: page,
            annotationBounds: annotation.bounds,
            quadrilateralPoints: quadrilateralPoints
        )
        let pdfKitRGBA = rgbaComponents(annotation.color)
        return PDFHighlight(
            page: pageIndex + 1,
            traversalIndex: annotationIndex,
            bounds: annotation.bounds,
            quadrilateralPoints: quadrilateralPoints,
            note: annotation.contents,
            pdfKitRGBA: pdfKitRGBA,
            presentationColor: PDFColorMapping.nearest(rgba: pdfKitRGBA),
            modifiedAt: annotation.modificationDate,
            text: text.text,
            textSource: text.source,
            textIsApproximate: text.isApproximate,
            textUnavailableReason: text.unavailableReason
        )
    }

    private func rgbaComponents(_ color: NSColor) -> [Double]? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return [
            Double(rgb.redComponent),
            Double(rgb.greenComponent),
            Double(rgb.blueComponent),
            Double(rgb.alphaComponent),
        ]
    }
}
