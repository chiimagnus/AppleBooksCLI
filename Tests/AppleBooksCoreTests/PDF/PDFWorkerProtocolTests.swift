import AppKit
import Foundation
import PDFKit
import Testing
@testable import AppleBooksCore

@Suite("PDFWorkerProtocolTests")
struct PDFWorkerProtocolTests {
    @Test
    func agentSummaryIsVersionedBoundedAndNeverEchoesPathOrRichGeometry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF(note: String(repeating: "n", count: 600))
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(
            path: pdf.path,
            mode: .agentSummary,
            limit: 20
        ))

        let invocation = PDFWorkerProtocol.run(requestData: request)
        let response = try PDFWorkerProtocol.decodeResponse(invocation.stdout)
        #expect(response.version == 2)
        #expect(response.status == .success)
        #expect(response.mode == .agentSummary)
        #expect(response.errorCode == nil)
        #expect(response.archiveHighlights == nil)
        let highlight = try #require(response.summaryHighlights?.first)
        #expect(highlight.page == 1)
        #expect(highlight.note?.count == 240)
        #expect(highlight.truncatedFields == ["note"])
        #expect(highlight.textApproximate)
        #expect(invocation.stderrCode == nil)
        let json = String(decoding: invocation.stdout, as: UTF8.self)
        #expect(json.contains(pdf.path) == false)
        for richField in ["traversalIndex", "bounds", "quadrilateralPoints", "pdfKitRGBA", "textSource"] {
            #expect(json.contains(richField) == false)
        }
    }

    @Test
    func archivePagesMoreThanOneHundredHighlightsWithoutDuplicatesOrOmissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF(count: 105)
        var continuation: PDFWorkerTraversal?
        var generation: String?
        var traversal: [Int] = []
        repeat {
            let response = try run(
                path: pdf.path,
                mode: .archive,
                limit: 20,
                continuation: continuation,
                generation: generation
            )
            #expect(response.status == .success)
            let items = try #require(response.archiveHighlights)
            #expect(items.count <= 20)
            traversal.append(contentsOf: items.map(\.traversalIndex))
            continuation = response.nextTraversal
            generation = response.generation
            if response.hasMore == false { continuation = nil }
        } while continuation != nil
        #expect(traversal == Array(0..<105))
    }

    @Test
    func malformedUnsupportedAndRequestSizeBoundariesFailWithoutReflectingInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF()
        let malformed = PDFWorkerProtocol.run(requestData: Data("not-json secret-path".utf8))
        #expect(try PDFWorkerProtocol.decodeResponse(malformed.stdout).errorCode == .malformedRequest)
        #expect(malformed.stderrCode == "malformedRequest")
        #expect(String(decoding: malformed.stdout, as: UTF8.self).contains("secret-path") == false)

        let unsupported = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(
            version: 99,
            path: "/private/secret.pdf",
            mode: .agentSummary,
            limit: 1
        ))
        let unsupportedInvocation = PDFWorkerProtocol.run(requestData: unsupported)
        #expect(try PDFWorkerProtocol.decodeResponse(unsupportedInvocation.stdout).errorCode == .unsupportedVersion)
        #expect(String(decoding: unsupportedInvocation.stdout, as: UTF8.self).contains("secret.pdf") == false)

        let prefix = "{\"version\":2,\"path\":\"\(pdf.path)\",\"mode\":\"agentSummary\",\"limit\":1,\"padding\":\""
        let suffix = "\"}"
        let paddingCount = PDFWorkerProtocol.requestByteLimit - prefix.utf8.count - suffix.utf8.count
        let exact = Data((prefix + String(repeating: "a", count: paddingCount) + suffix).utf8)
        #expect(exact.count == PDFWorkerProtocol.requestByteLimit)
        #expect(try PDFWorkerProtocol.decodeResponse(PDFWorkerProtocol.run(requestData: exact).stdout).status == .success)

        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let oversized = exact + Data([0x20])
        DispatchQueue.global().async { writer.write(oversized) }
        let tooLarge = PDFWorkerProtocol.run(requestHandle: pipe.fileHandleForReading)
        #expect(try PDFWorkerProtocol.decodeResponse(tooLarge.stdout).errorCode == .requestTooLarge)
        try? writer.close()
    }

    @Test
    func pathValidationRejectsRelativeWrongFormatAndSymlinkBeforePDFKit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF()
        #expect(try run(path: "relative.pdf").errorCode == .invalidPath)

        let text = fixture.root.appendingPathComponent("not-pdf.txt")
        try Data("plain".utf8).write(to: text)
        #expect(try run(path: text.path).errorCode == .unsupportedFormat)

        let symlink = fixture.root.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: pdf)
        #expect(try run(path: symlink.path).errorCode == .unsafeFile)
    }

    @Test
    func replacementAfterOpenReadsHeldDescriptorAndNextPageDetectsStaleSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.highlightPDF(name: "race.pdf", note: "original", count: 2)
        let replacement = try fixture.highlightPDF(name: "replacement.pdf", note: "replacement")
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(
            path: original.path,
            mode: .agentSummary,
            limit: 1
        ))
        let raced = PDFWorkerProtocol.run(requestData: request, afterOpen: {
            try! FileManager.default.removeItem(at: original)
            try! FileManager.default.moveItem(at: replacement, to: original)
        })
        let racedResponse = try PDFWorkerProtocol.decodeResponse(raced.stdout)
        #expect(racedResponse.summaryHighlights?.first?.note == "original-0")

        let fresh = try fixture.highlightPDF(name: "stale.pdf", note: "first", count: 2)
        let first = try run(path: fresh.path, mode: .agentSummary, limit: 1)
        let continuation = try #require(first.nextTraversal)
        let generation = try #require(first.generation)
        let changed = try fixture.highlightPDF(name: "changed.pdf", note: "changed")
        try FileManager.default.removeItem(at: fresh)
        try FileManager.default.moveItem(at: changed, to: fresh)
        let stale = try run(
            path: fresh.path,
            mode: .agentSummary,
            limit: 1,
            continuation: continuation,
            generation: generation
        )
        #expect(stale.status == .failure)
        #expect(stale.errorCode == .staleSource)
    }

    @Test
    func regularFileReplacedBySymlinkFailsClosedOnNextWorkerOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF()
        #expect(try run(path: pdf.path).status == .success)
        let outside = fixture.root.appendingPathComponent("outside.pdf")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: pdf)
        try FileManager.default.createSymbolicLink(at: pdf, withDestinationURL: outside)
        #expect(try run(path: pdf.path).errorCode == .unsafeFile)
    }

    @Test
    func corruptPDFIsStructuredFailureRatherThanEmptySuccess() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PDF/corrupt.pdf")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let response = try run(path: fixtureURL.path)
        #expect(response.status == .failure)
        #expect(response.summaryHighlights == nil)
        #expect(response.archiveHighlights == nil)
        #expect(response.errorCode == .unreadableDocument)
    }

    private func run(
        path: String,
        mode: PDFWorkerMode = .agentSummary,
        limit: Int = 20,
        continuation: PDFWorkerTraversal? = nil,
        generation: String? = nil
    ) throws -> PDFWorkerResponse {
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(
            path: path,
            mode: mode,
            limit: limit,
            continuation: continuation,
            generation: generation
        ))
        return try PDFWorkerProtocol.decodeResponse(PDFWorkerProtocol.run(requestData: request).stdout)
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func highlightPDF(
            name: String = "valid.pdf",
            note: String = "protocol note",
            count: Int = 1
        ) throws -> URL {
            let image = NSImage(size: NSSize(width: 200, height: 200))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
            image.unlockFocus()
            let page = try #require(PDFPage(image: image))
            for index in 0..<count {
                let annotation = PDFAnnotation(
                    bounds: CGRect(x: 20, y: 20, width: 80, height: 15),
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.contents = count == 1 ? note : "\(note)-\(index)"
                page.addAnnotation(annotation)
            }
            let document = PDFDocument()
            document.insert(page, at: 0)
            let url = root.appendingPathComponent(name)
            guard document.write(to: url) else { throw FixtureError.writeFailed }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureError: Error {
        case writeFailed
    }
}
