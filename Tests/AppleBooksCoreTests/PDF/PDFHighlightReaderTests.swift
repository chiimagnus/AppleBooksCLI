import Foundation
import PDFKit
import Testing
@testable import AppleBooksCore

@Suite("PDFHighlightReaderTests")
struct PDFHighlightReaderTests {
    @Test
    func readsOnlyHighlightMetadataWithOneBasedPageAndTraversalIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let modified = Date(timeIntervalSince1970: 1_700_000_123)
        let url = try fixture.writeMinimalPDF(
            name: "highlight.pdf",
            annotationDictionaries: [
                "<< /Type /Annot /Subtype /Link /Rect [5 5 15 15] /Border [0 0 0] >>",
                "<< /Type /Annot /Subtype /Highlight /Rect [10 20 110 35] /QuadPoints [10 35 110 35 10 20 110 20] /Contents (synthetic note) /M (D:20231114221523Z) /C [0.2 0.4 0.6] >>",
            ]
        )

        let highlights = try PDFHighlightReader().read(fileURL: url)
        let highlight = try #require(highlights.first)
        #expect(highlights.count == 1)
        #expect(highlight.page == 1)
        #expect(highlight.traversalIndex == 1)
        #expect(highlight.bounds == CGRect(x: 10, y: 20, width: 100, height: 15))
        #expect(highlight.quadrilateralPoints.count == 4)
        #expect(highlight.note == "synthetic note")
        #expect(abs((highlight.modifiedAt ?? .distantPast).timeIntervalSince(modified)) < 1)
        let rgba = try #require(highlight.pdfKitRGBA)
        #expect(rgba.count == 4)
        #expect(abs(rgba[0] - 0.2) < 0.01)
        #expect(abs(rgba[1] - 0.4) < 0.01)
        #expect(abs(rgba[2] - 0.6) < 0.01)
        #expect(abs(rgba[3] - 1.0) < 0.01)
    }

    @Test
    func successfulEnumerationMayReturnZeroHighlightsOrMissingMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let emptyURL = try fixture.writeMinimalPDF(name: "empty.pdf", annotationDictionaries: [])
        #expect(try PDFHighlightReader().read(fileURL: emptyURL).isEmpty)

        let missingURL = try fixture.writeMinimalPDF(
            name: "missing-metadata.pdf",
            annotationDictionaries: [
                "<< /Type /Annot /Subtype /Highlight /Rect [1 2 21 7] >>",
            ]
        )
        let highlight = try #require(try PDFHighlightReader().read(fileURL: missingURL).first)
        #expect(highlight.note == nil)
        #expect(highlight.modifiedAt == nil)
    }

    @Test
    func corruptPDFIsFailureRatherThanEmptySuccess() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PDF/corrupt.pdf")

        #expect(throws: PDFHighlightReaderError.unreadableDocument) {
            _ = try PDFHighlightReader().read(fileURL: fixtureURL)
        }
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writeMinimalPDF(name: String, annotationDictionaries: [String]) throws -> URL {
            let refs = annotationDictionaries.indices.map { "\($0 + 4) 0 R" }.joined(separator: " ")
            let annots = refs.isEmpty ? "" : " /Annots [\(refs)]"
            var objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]\(annots) >>",
            ]
            objects.append(contentsOf: annotationDictionaries)

            var data = Data("%PDF-1.4\n".utf8)
            var offsets: [Int] = [0]
            for (index, object) in objects.enumerated() {
                offsets.append(data.count)
                data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
            }
            let xrefOffset = data.count
            data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
            for offset in offsets.dropFirst() {
                data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            }
            data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))

            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
