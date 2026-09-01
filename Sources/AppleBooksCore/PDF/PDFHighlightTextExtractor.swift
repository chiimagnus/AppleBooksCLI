import CoreGraphics
import Foundation
import PDFKit

public enum PDFHighlightTextSource: String, Equatable, Sendable {
    case quadSelection
    case boundsFallback
}

public enum PDFHighlightTextUnavailableReason: String, Equatable, Sendable {
    case noTextSelection
}

struct PDFHighlightTextExtraction: Equatable {
    let text: String?
    let source: PDFHighlightTextSource?
    let isApproximate: Bool
    let unavailableReason: PDFHighlightTextUnavailableReason?
}

struct PDFHighlightTextExtractor {
    func extract(
        page: PDFPage,
        annotationBounds: CGRect,
        quadrilateralPoints: [CGPoint]
    ) -> PDFHighlightTextExtraction {
        let quadRects = usableQuadRects(
            points: quadrilateralPoints,
            annotationOrigin: annotationBounds.origin
        )
        if quadRects.isEmpty == false {
            let text = joinedSelectionText(quadRects.compactMap { page.selection(for: $0)?.string })
            return result(text: text, source: .quadSelection)
        }

        let fallbackText: String?
        if annotationBounds.isNull || annotationBounds.isEmpty || annotationBounds.isInfinite {
            fallbackText = nil
        } else {
            fallbackText = page.selection(for: annotationBounds)?.string
        }
        return result(text: joinedSelectionText([fallbackText].compactMap { $0 }), source: .boundsFallback)
    }

    private func result(text: String?, source: PDFHighlightTextSource) -> PDFHighlightTextExtraction {
        guard let text else {
            return PDFHighlightTextExtraction(
                text: nil,
                source: nil,
                isApproximate: true,
                unavailableReason: .noTextSelection
            )
        }
        return PDFHighlightTextExtraction(
            text: text,
            source: source,
            isApproximate: true,
            unavailableReason: nil
        )
    }

    private func usableQuadRects(points: [CGPoint], annotationOrigin: CGPoint) -> [CGRect] {
        guard points.count >= 4 else { return [] }
        var rectangles: [CGRect] = []
        for start in stride(from: 0, through: points.count - 4, by: 4) {
            let pagePoints = points[start..<(start + 4)].map {
                CGPoint(x: $0.x + annotationOrigin.x, y: $0.y + annotationOrigin.y)
            }
            guard pagePoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let minX = pagePoints.map(\.x).min() ?? 0
            let maxX = pagePoints.map(\.x).max() ?? 0
            let minY = pagePoints.map(\.y).min() ?? 0
            let maxY = pagePoints.map(\.y).max() ?? 0
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard rect.isEmpty == false, rect.isNull == false, rect.isInfinite == false else { continue }
            rectangles.append(rect)
        }
        return rectangles
    }

    private func joinedSelectionText(_ strings: [String]) -> String? {
        let segments = strings.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard segments.isEmpty == false else { return nil }
        return segments.joined(separator: " ")
    }
}
