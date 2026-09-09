import CoreGraphics
import Foundation

public enum PDFHighlightServiceFailureReason: Equatable, Sendable {
    case timeout
    case worker(PDFWorkerClientError)
    case internalFailure
}

public struct PDFHighlightServiceFailure: Equatable, Sendable {
    public let source: PDFSource
    public let reason: PDFHighlightServiceFailureReason
}

public struct PDFDocumentHighlights: Equatable, Sendable {
    public let source: PDFSource
    public let highlights: [PDFHighlight]
}

public struct PDFHighlightServiceResult: Equatable, Sendable {
    public let documents: [PDFDocumentHighlights]
    public let failures: [PDFHighlightServiceFailure]
    public let attemptedCount: Int
    public let succeededCount: Int
    public let noHighlightsCount: Int
    public let failedCount: Int
    public let timeoutCount: Int
}

struct PDFHighlightService {
    let bookQueries: BookQueries
    let sourceResolver: PDFSourceResolver
    let workerClient: PDFWorkerClient

    func inventory() throws -> [PDFSource] {
        sourceResolver.resolve(pdfBooks: try bookQueries.pdfBooks())
    }

    func readHighlights() throws -> PDFHighlightServiceResult {
        readHighlights(sources: try inventory())
    }

    func readHighlights(sources: [PDFSource]) -> PDFHighlightServiceResult {
        var documents: [PDFDocumentHighlights] = []
        var failures: [PDFHighlightServiceFailure] = []

        for source in sources {
            do {
                let highlights = try workerClient.read(fileURL: source.fileURL).map(\.domainValue)
                documents.append(PDFDocumentHighlights(source: source, highlights: highlights))
            } catch PDFWorkerClientError.timedOut {
                failures.append(PDFHighlightServiceFailure(source: source, reason: .timeout))
            } catch let error as PDFWorkerClientError {
                failures.append(PDFHighlightServiceFailure(source: source, reason: .worker(error)))
            } catch {
                failures.append(PDFHighlightServiceFailure(source: source, reason: .internalFailure))
            }
        }

        let noHighlights = documents.count { $0.highlights.isEmpty }
        let timeouts = failures.count { $0.reason == .timeout }
        return PDFHighlightServiceResult(
            documents: documents,
            failures: failures,
            attemptedCount: sources.count,
            succeededCount: documents.count,
            noHighlightsCount: noHighlights,
            failedCount: failures.count,
            timeoutCount: timeouts
        )
    }
}

private extension PDFWorkerHighlight {
    var domainValue: PDFHighlight {
        let mappedColor: PDFColorMatch?
        if let presentationColor,
           let color = PDFPresentationColor(rawValue: presentationColor.color) {
            mappedColor = PDFColorMatch(
                color: color,
                distance: presentationColor.distance,
                isApproximate: presentationColor.isApproximate
            )
        } else {
            mappedColor = nil
        }
        return PDFHighlight(
            page: page,
            traversalIndex: traversalIndex,
            bounds: CGRect(
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height
            ),
            quadrilateralPoints: quadrilateralPoints.map { CGPoint(x: $0.x, y: $0.y) },
            note: note,
            pdfKitRGBA: pdfKitRGBA,
            presentationColor: mappedColor,
            modifiedAt: modifiedAt,
            text: text,
            textSource: textSource.flatMap(PDFHighlightTextSource.init(rawValue:)),
            textIsApproximate: textIsApproximate,
            textUnavailableReason: textUnavailableReason.flatMap(PDFHighlightTextUnavailableReason.init(rawValue:))
        )
    }
}
