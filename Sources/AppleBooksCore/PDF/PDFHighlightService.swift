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

package struct PDFDocumentHighlights: Equatable, Sendable {
    package let source: PDFSource
    package let highlights: [PDFHighlight]
}

package struct PDFHighlightServiceResult: Equatable, Sendable {
    package let documents: [PDFDocumentHighlights]
    package let failures: [PDFHighlightServiceFailure]
    package let attemptedCount: Int
    package let succeededCount: Int
    package let noHighlightsCount: Int
    package let failedCount: Int
    package let timeoutCount: Int
}

package struct PDFAgentPresentationColor: Equatable, Sendable {
    package let name: PDFPresentationColor
    package let approximate: Bool
}

package struct PDFAgentHighlightSummary: Equatable, Sendable {
    package let page: Int
    package let note: String?
    package let text: String?
    package let modifiedAt: Date?
    package let textApproximate: Bool
    package let presentationColor: PDFAgentPresentationColor?
    package let truncatedFields: [String]
}

package struct PDFAgentWorkerPage: Equatable, Sendable {
    package let items: [PDFAgentHighlightSummary]
    package let nextTraversal: PDFWorkerTraversal?
    package let hasMore: Bool
    package let generation: String
}

package struct SemanticPDFHighlightPage: Equatable, Sendable {
    package let bookAssetID: String?
    package let pdfSourceID: String?
    package let items: [PDFAgentHighlightSummary]
    package let nextCursor: String?
    package let hasMore: Bool
}

struct PDFHighlightService {
    let bookQueries: BookQueries
    let sourceResolver: PDFSourceResolver
    let workerClient: PDFWorkerClient

    func inventory() throws -> [PDFSource] {
        try sourceResolver.exportInventory(bookQueries: bookQueries)
    }

    func readAgentPage(
        source: PDFSource,
        limit: Int,
        continuation: PDFWorkerTraversal?,
        generation: String?
    ) throws -> PDFAgentWorkerPage {
        let page = try workerClient.readPage(
            fileURL: source.fileURL,
            mode: .agentSummary,
            limit: limit,
            continuation: continuation,
            generation: generation
        )
        let items = try page.summaryHighlights.map { item -> PDFAgentHighlightSummary in
            let color: PDFAgentPresentationColor?
            if let raw = item.presentationColor {
                guard let name = PDFPresentationColor(rawValue: raw.name) else {
                    throw PDFWorkerClientError.malformedResponse
                }
                color = PDFAgentPresentationColor(name: name, approximate: raw.approximate)
            } else {
                color = nil
            }
            return PDFAgentHighlightSummary(
                page: item.page,
                note: item.note,
                text: item.text,
                modifiedAt: item.modifiedAt,
                textApproximate: item.textApproximate,
                presentationColor: color,
                truncatedFields: item.truncatedFields
            )
        }
        return PDFAgentWorkerPage(
            items: items,
            nextTraversal: page.nextTraversal,
            hasMore: page.hasMore,
            generation: page.generation
        )
    }

    func readHighlights(sources: [PDFSource]) -> PDFHighlightServiceResult {
        var documents: [PDFDocumentHighlights] = []
        var failures: [PDFHighlightServiceFailure] = []

        for source in sources {
            do {
                let highlights = try readArchiveHighlights(source: source)
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

    private func readArchiveHighlights(source: PDFSource) throws -> [PDFHighlight] {
        var result: [PDFHighlight] = []
        var continuation: PDFWorkerTraversal?
        var generation: String?
        repeat {
            let page = try workerClient.readPage(
                fileURL: source.fileURL,
                mode: .archive,
                limit: PDFWorkerProtocol.maximumPageLimit,
                continuation: continuation,
                generation: generation
            )
            result.append(contentsOf: try page.archiveHighlights.map { try $0.domainValue() })
            if page.hasMore {
                guard let next = page.nextTraversal else {
                    throw PDFWorkerClientError.malformedResponse
                }
                continuation = next
                generation = page.generation
            } else {
                continuation = nil
            }
        } while continuation != nil
        return result
    }
}

private extension PDFWorkerArchiveHighlight {
    func domainValue() throws -> PDFHighlight {
        let mappedColor: PDFColorMatch?
        if let presentationColor {
            guard let color = PDFPresentationColor(rawValue: presentationColor.color) else {
                throw PDFWorkerClientError.malformedResponse
            }
            mappedColor = PDFColorMatch(
                color: color,
                distance: presentationColor.distance,
                isApproximate: presentationColor.isApproximate
            )
        } else {
            mappedColor = nil
        }
        let mappedTextSource: PDFHighlightTextSource?
        if let textSource {
            guard let value = PDFHighlightTextSource(rawValue: textSource) else {
                throw PDFWorkerClientError.malformedResponse
            }
            mappedTextSource = value
        } else {
            mappedTextSource = nil
        }
        let mappedUnavailableReason: PDFHighlightTextUnavailableReason?
        if let textUnavailableReason {
            guard let value = PDFHighlightTextUnavailableReason(rawValue: textUnavailableReason) else {
                throw PDFWorkerClientError.malformedResponse
            }
            mappedUnavailableReason = value
        } else {
            mappedUnavailableReason = nil
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
            textSource: mappedTextSource,
            textIsApproximate: textIsApproximate,
            textUnavailableReason: mappedUnavailableReason
        )
    }
}
