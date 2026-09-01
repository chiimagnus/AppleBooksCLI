import CoreGraphics
import Foundation

public struct PDFHighlight: Equatable, Sendable {
    public let page: Int
    public let traversalIndex: Int
    public let bounds: CGRect
    public let quadrilateralPoints: [CGPoint]
    public let note: String?
    public let pdfKitRGBA: [Double]?
    public let modifiedAt: Date?
    public let text: String?
    public let textSource: PDFHighlightTextSource?
    public let textIsApproximate: Bool
    public let textUnavailableReason: PDFHighlightTextUnavailableReason?

    init(
        page: Int,
        traversalIndex: Int,
        bounds: CGRect,
        quadrilateralPoints: [CGPoint],
        note: String?,
        pdfKitRGBA: [Double]?,
        modifiedAt: Date?,
        text: String? = nil,
        textSource: PDFHighlightTextSource? = nil,
        textIsApproximate: Bool = true,
        textUnavailableReason: PDFHighlightTextUnavailableReason? = .noTextSelection
    ) {
        self.page = page
        self.traversalIndex = traversalIndex
        self.bounds = bounds
        self.quadrilateralPoints = quadrilateralPoints
        self.note = note
        self.pdfKitRGBA = pdfKitRGBA
        self.modifiedAt = modifiedAt
        self.text = text
        self.textSource = textSource
        self.textIsApproximate = textIsApproximate
        self.textUnavailableReason = textUnavailableReason
    }
}
