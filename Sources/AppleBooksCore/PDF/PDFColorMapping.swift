import Foundation

public enum PDFPresentationColor: String, CaseIterable, Equatable, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple
}

public struct PDFColorMatch: Equatable, Sendable {
    public let color: PDFPresentationColor
    public let distance: Double
    public let isApproximate: Bool
}

enum PDFColorMapping {
    private static let palette: [(PDFPresentationColor, (Double, Double, Double))] = [
        (.green, (0.48, 0.78, 0.42)),
        (.blue, (0.36, 0.64, 0.94)),
        (.yellow, (1.00, 1.00, 0.00)),
        (.pink, (0.95, 0.48, 0.66)),
        (.purple, (0.65, 0.50, 0.86)),
    ]

    static func nearest(rgba: [Double]?) -> PDFColorMatch? {
        guard let rgba, rgba.count >= 3,
              rgba[0].isFinite, rgba[1].isFinite, rgba[2].isFinite else {
            return nil
        }
        let red = rgba[0]
        let green = rgba[1]
        let blue = rgba[2]
        guard (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue) else {
            return nil
        }

        let nearest = palette.min { lhs, rhs in
            distance(red: red, green: green, blue: blue, to: lhs.1)
                < distance(red: red, green: green, blue: blue, to: rhs.1)
        }
        guard let nearest else { return nil }
        return PDFColorMatch(
            color: nearest.0,
            distance: distance(red: red, green: green, blue: blue, to: nearest.1),
            isApproximate: true
        )
    }

    private static func distance(
        red: Double,
        green: Double,
        blue: Double,
        to target: (Double, Double, Double)
    ) -> Double {
        let dr = red - target.0
        let dg = green - target.1
        let db = blue - target.2
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
