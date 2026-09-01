import AppKit
import Foundation
import PDFKit
import Testing
@testable import AppleBooksCore

@Suite("PDFColorMappingTests")
struct PDFColorMappingTests {
    @Test
    func nearestPaletteAlwaysKeepsApproximateProvenance() throws {
        let fixtures: [([Double], PDFPresentationColor)] = [
            ([0.50, 0.80, 0.40, 1], .green),
            ([0.35, 0.65, 0.95, 1], .blue),
            ([1.00, 1.00, 0.00, 1], .yellow),
            ([0.95, 0.50, 0.65, 1], .pink),
            ([0.65, 0.50, 0.85, 1], .purple),
        ]

        for (rgba, expected) in fixtures {
            let match = try #require(PDFColorMapping.nearest(rgba: rgba))
            #expect(match.color == expected)
            #expect(match.distance >= 0)
            #expect(match.isApproximate)
        }
    }

    @Test
    func invalidOrUnavailablePlatformColorDoesNotInventPresentationColor() {
        #expect(PDFColorMapping.nearest(rgba: nil) == nil)
        #expect(PDFColorMapping.nearest(rgba: []) == nil)
        #expect(PDFColorMapping.nearest(rgba: [.nan, 0, 0, 1]) == nil)
        #expect(PDFColorMapping.nearest(rgba: [1.2, 0, 0, 1]) == nil)
    }

    @Test
    func pdfKitDefaultHighlightColorIsYellowButNotClaimedRaw() throws {
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 12),
            forType: .highlight,
            withProperties: nil
        )
        let rgb = try #require(annotation.color.usingColorSpace(.sRGB))
        let rgba = [
            Double(rgb.redComponent),
            Double(rgb.greenComponent),
            Double(rgb.blueComponent),
            Double(rgb.alphaComponent),
        ]
        #expect(rgba == [1, 1, 0, 1])
        let match = try #require(PDFColorMapping.nearest(rgba: rgba))
        #expect(match.color == .yellow)
        #expect(match.isApproximate)
    }

    @Test
    func readerPreservesPDFKitModifiedInstantAndPlatformColor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))

        let modified = Date(timeIntervalSince1970: 1_700_000_123)
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 80, height: 15),
            forType: .highlight,
            withProperties: nil
        )
        annotation.modificationDate = modified
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let url = root.appendingPathComponent("roundtrip.pdf")
        #expect(document.write(to: url))

        let highlight = try #require(try PDFHighlightReader().read(fileURL: url).first)
        #expect(abs((highlight.modifiedAt ?? .distantPast).timeIntervalSince(modified)) < 1)
        let rgba = try #require(highlight.pdfKitRGBA)
        #expect(rgba.count == 4)
        #expect(abs(rgba[0] - 1) < 0.001)
        #expect(abs(rgba[1] - 1) < 0.001)
        #expect(abs(rgba[2]) < 0.001)
        #expect(highlight.presentationColor?.color == .yellow)
        #expect(highlight.presentationColor?.isApproximate == true)
    }
}
