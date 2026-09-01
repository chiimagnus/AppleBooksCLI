import AppKit
import Foundation
import PDFKit
import Testing
@testable import AppleBooksCore

@Suite("PDFWorkerProtocolTests")
struct PDFWorkerProtocolTests {
    @Test
    func validCanonicalPDFReturnsVersionedHighlightEnvelopeWithoutPathEcho() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF().standardizedFileURL.resolvingSymlinksInPath()
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(path: pdf.path))

        let invocation = PDFWorkerProtocol.run(requestData: request)
        let response = try PDFWorkerProtocol.decodeResponse(invocation.stdout)
        #expect(response.version == PDFWorkerProtocol.version)
        #expect(response.status == .success)
        #expect(response.errorCode == nil)
        let highlight = try #require(response.highlights?.first)
        #expect(highlight.page == 1)
        #expect(highlight.note == "protocol note")
        #expect(highlight.presentationColor?.color == "yellow")
        #expect(invocation.stderrCode == nil)
        #expect(String(decoding: invocation.stdout, as: UTF8.self).contains(pdf.path) == false)
    }

    @Test
    func malformedAndUnsupportedRequestsFailWithoutReflectingInput() throws {
        let malformed = PDFWorkerProtocol.run(requestData: Data("not-json secret-path".utf8))
        #expect(try PDFWorkerProtocol.decodeResponse(malformed.stdout).errorCode == .malformedRequest)
        #expect(malformed.stderrCode == "malformedRequest")
        #expect(String(decoding: malformed.stdout, as: UTF8.self).contains("secret-path") == false)

        let unsupported = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(version: 99, path: "/private/secret.pdf"))
        let unsupportedInvocation = PDFWorkerProtocol.run(requestData: unsupported)
        #expect(try PDFWorkerProtocol.decodeResponse(unsupportedInvocation.stdout).errorCode == .unsupportedVersion)
        #expect(String(decoding: unsupportedInvocation.stdout, as: UTF8.self).contains("secret.pdf") == false)
    }

    @Test
    func pathValidationRejectsRelativeWrongFormatAndSymlinkBeforePDFKit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pdf = try fixture.highlightPDF().standardizedFileURL.resolvingSymlinksInPath()

        let relative = try run(path: "relative.pdf")
        #expect(relative.errorCode == .invalidPath)

        let text = fixture.root.appendingPathComponent("not-pdf.txt")
        try Data("plain".utf8).write(to: text)
        let wrongFormat = try run(path: text.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(wrongFormat.errorCode == .unsupportedFormat)

        let symlink = fixture.root.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: pdf)
        let linked = try run(path: symlink.standardizedFileURL.path)
        #expect(linked.errorCode == .unsafeFile)
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
        #expect(response.highlights == nil)
        #expect(response.errorCode == .unreadableDocument)
    }

    private func run(path: String) throws -> PDFWorkerResponse {
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(path: path))
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

        func highlightPDF() throws -> URL {
            let image = NSImage(size: NSSize(width: 200, height: 200))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
            image.unlockFocus()
            let page = try #require(PDFPage(image: image))
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 20, y: 20, width: 80, height: 15),
                forType: .highlight,
                withProperties: nil
            )
            annotation.contents = "protocol note"
            page.addAnnotation(annotation)
            let document = PDFDocument()
            document.insert(page, at: 0)
            let url = root.appendingPathComponent("valid.pdf")
            guard document.write(to: url) else { throw FixtureError.writeFailed }
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureError: Error {
        case writeFailed
    }
}
