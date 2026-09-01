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

    init(
        page: Int,
        traversalIndex: Int,
        bounds: CGRect,
        quadrilateralPoints: [CGPoint],
        note: String?,
        pdfKitRGBA: [Double]?,
        modifiedAt: Date?
    ) {
        self.page = page
        self.traversalIndex = traversalIndex
        self.bounds = bounds
        self.quadrilateralPoints = quadrilateralPoints
        self.note = note
        self.pdfKitRGBA = pdfKitRGBA
        self.modifiedAt = modifiedAt
    }
}
