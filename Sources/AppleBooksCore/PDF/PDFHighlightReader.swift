import AppKit
import Foundation
import PDFKit

public enum PDFHighlightReaderError: Error, Equatable, Sendable {
    case unreadableDocument
    case pageUnavailable(Int)
}

struct PDFHighlightReader {
    func read(fileURL: URL) throws -> [PDFHighlight] {
        guard let document = PDFDocument(url: fileURL) else {
            throw PDFHighlightReaderError.unreadableDocument
        }

        var highlights: [PDFHighlight] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw PDFHighlightReaderError.pageUnavailable(pageIndex + 1)
            }
            for (annotationIndex, annotation) in page.annotations.enumerated() {
                guard annotation.type == "Highlight" else { continue }
                let quadrilateralPoints = annotation.quadrilateralPoints?.map(\.pointValue) ?? []
                let text = PDFHighlightTextExtractor().extract(
                    page: page,
                    annotationBounds: annotation.bounds,
                    quadrilateralPoints: quadrilateralPoints
                )
                let pdfKitRGBA = rgbaComponents(annotation.color)
                highlights.append(
                    PDFHighlight(
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
                )
            }
        }
        return highlights
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
