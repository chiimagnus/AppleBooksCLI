import CryptoKit
import Darwin
import Foundation

enum PDFWorkerStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
}

public enum PDFWorkerErrorCode: String, Codable, Equatable, Sendable {
    case malformedRequest
    case requestTooLarge
    case unsupportedVersion
    case invalidPath
    case unsupportedFormat
    case unsafeFile
    case staleSource
    case unreadableDocument
    case pageUnavailable
    case internalFailure
}

enum PDFWorkerMode: String, Codable, Equatable, Sendable {
    case agentSummary
    case archive
}

struct PDFWorkerTraversal: Codable, Equatable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int

    init(pageIndex: Int, annotationIndex: Int) {
        self.pageIndex = pageIndex
        self.annotationIndex = annotationIndex
    }
}

struct PDFWorkerRequest: Codable, Equatable, Sendable {
    let version: Int
    let path: String
    let mode: PDFWorkerMode
    let limit: Int
    let continuation: PDFWorkerTraversal?
    let generation: String?

    init(
        version: Int = PDFWorkerProtocol.version,
        path: String,
        mode: PDFWorkerMode,
        limit: Int,
        continuation: PDFWorkerTraversal? = nil,
        generation: String? = nil
    ) {
        self.version = version
        self.path = path
        self.mode = mode
        self.limit = limit
        self.continuation = continuation
        self.generation = generation
    }
}

struct PDFWorkerPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct PDFWorkerRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct PDFWorkerColorMatch: Codable, Equatable, Sendable {
    let color: String
    let distance: Double
    let isApproximate: Bool
}

struct PDFWorkerSummaryColor: Codable, Equatable, Sendable {
    let name: String
    let approximate: Bool
}

struct PDFWorkerSummaryHighlight: Codable, Equatable, Sendable {
    let page: Int
    let note: String?
    let text: String?
    let modifiedAt: Date?
    let textApproximate: Bool
    let presentationColor: PDFWorkerSummaryColor?
    let truncatedFields: [String]

    init(_ highlight: PDFHighlight) {
        let boundedNote = PDFWorkerProtocol.agentPreview(highlight.note)
        let boundedText = PDFWorkerProtocol.agentPreview(highlight.text)
        page = highlight.page
        note = boundedNote.value
        text = boundedText.value
        modifiedAt = highlight.modifiedAt
        textApproximate = true
        presentationColor = highlight.presentationColor.map {
            PDFWorkerSummaryColor(name: $0.color.rawValue, approximate: true)
        }
        var truncated: [String] = []
        if boundedNote.truncated { truncated.append("note") }
        if boundedText.truncated { truncated.append("text") }
        truncatedFields = truncated
    }
}

struct PDFWorkerArchiveHighlight: Codable, Equatable, Sendable {
    let page: Int
    let traversalIndex: Int
    let bounds: PDFWorkerRect
    let quadrilateralPoints: [PDFWorkerPoint]
    let note: String?
    let pdfKitRGBA: [Double]?
    let presentationColor: PDFWorkerColorMatch?
    let modifiedAt: Date?
    let text: String?
    let textSource: String?
    let textIsApproximate: Bool
    let textUnavailableReason: String?

    init(_ highlight: PDFHighlight) {
        page = highlight.page
        traversalIndex = highlight.traversalIndex
        bounds = PDFWorkerRect(
            x: Double(highlight.bounds.origin.x),
            y: Double(highlight.bounds.origin.y),
            width: Double(highlight.bounds.size.width),
            height: Double(highlight.bounds.size.height)
        )
        quadrilateralPoints = highlight.quadrilateralPoints.map {
            PDFWorkerPoint(x: Double($0.x), y: Double($0.y))
        }
        note = highlight.note
        pdfKitRGBA = highlight.pdfKitRGBA
        presentationColor = highlight.presentationColor.map {
            PDFWorkerColorMatch(
                color: $0.color.rawValue,
                distance: $0.distance,
                isApproximate: $0.isApproximate
            )
        }
        modifiedAt = highlight.modifiedAt
        text = highlight.text
        textSource = highlight.textSource?.rawValue
        textIsApproximate = highlight.textIsApproximate
        textUnavailableReason = highlight.textUnavailableReason?.rawValue
    }
}

struct PDFWorkerResponse: Codable, Equatable, Sendable {
    let version: Int
    let status: PDFWorkerStatus
    let mode: PDFWorkerMode?
    let summaryHighlights: [PDFWorkerSummaryHighlight]?
    let archiveHighlights: [PDFWorkerArchiveHighlight]?
    let nextTraversal: PDFWorkerTraversal?
    let hasMore: Bool?
    let generation: String?
    let errorCode: PDFWorkerErrorCode?
}

package struct PDFWorkerInvocation: Equatable, Sendable {
    package let stdout: Data
    package let stderrCode: String?
}

package enum PDFWorkerProtocol {
    static let version = 2
    static let requestByteLimit = 64 * 1_024
    static let maximumPageLimit = 100
    static let agentPreviewMaximumGraphemes = 240
    static let agentPreviewMaximumUTF8Bytes = 4 * 1_024
    private static let maximumPathUTF8Bytes = 4 * 1_024
    private static let generationPrefix = "pdfg2_"
    private static let generationDigestByteCount = 32

    static func encodeRequest(_ request: PDFWorkerRequest) throws -> Data {
        try encoder().encode(request)
    }

    static func decodeResponse(_ data: Data) throws -> PDFWorkerResponse {
        try decoder().decode(PDFWorkerResponse.self, from: data)
    }

    package static func run(requestHandle: FileHandle) -> PDFWorkerInvocation {
        var requestData = Data()
        requestData.reserveCapacity(4 * 1_024)
        while true {
            let remaining = requestByteLimit - requestData.count
            let readCount = max(1, min(8 * 1_024, remaining + 1))
            let chunk: Data
            do {
                chunk = try requestHandle.read(upToCount: readCount) ?? Data()
            } catch {
                return failure(.malformedRequest)
            }
            if chunk.isEmpty {
                return run(requestData: requestData, afterOpen: nil)
            }
            guard chunk.count <= remaining else {
                return failure(.requestTooLarge)
            }
            requestData.append(chunk)
        }
    }

    static func run(requestData: Data, afterOpen: (() -> Void)?) -> PDFWorkerInvocation {
        guard requestData.count <= requestByteLimit else { return failure(.requestTooLarge) }
        let request: PDFWorkerRequest
        do {
            request = try decoder().decode(PDFWorkerRequest.self, from: requestData)
        } catch {
            return failure(.malformedRequest)
        }
        guard request.version == version else { return failure(.unsupportedVersion) }
        guard validate(request) else { return failure(.malformedRequest) }

        let file: ValidatedPDFWorkerFile
        do {
            file = try openValidatedPDF(path: request.path)
        } catch let code as PDFWorkerErrorCode {
            return failure(code)
        } catch {
            return failure(.internalFailure)
        }
        defer { close(file.descriptor) }

        do {
            let beforeGeneration = try generationToken(descriptor: file.descriptor)
            if let expected = request.generation, expected != beforeGeneration {
                return failure(.staleSource)
            }
            afterOpen?()
            let page = try PDFHighlightReader().readPage(
                fileURL: file.descriptorURL,
                start: request.continuation,
                limit: request.limit
            )
            let afterGeneration = try generationToken(descriptor: file.descriptor)
            guard afterGeneration == beforeGeneration else { return failure(.staleSource) }
            let hasMore = page.nextTraversal != nil
            let result: PDFWorkerResponse
            switch request.mode {
            case .agentSummary:
                result = PDFWorkerResponse(
                    version: version,
                    status: .success,
                    mode: .agentSummary,
                    summaryHighlights: page.highlights.map(PDFWorkerSummaryHighlight.init),
                    archiveHighlights: nil,
                    nextTraversal: page.nextTraversal,
                    hasMore: hasMore,
                    generation: beforeGeneration,
                    errorCode: nil
                )
            case .archive:
                result = PDFWorkerResponse(
                    version: version,
                    status: .success,
                    mode: .archive,
                    summaryHighlights: nil,
                    archiveHighlights: page.highlights.map(PDFWorkerArchiveHighlight.init),
                    nextTraversal: page.nextTraversal,
                    hasMore: hasMore,
                    generation: beforeGeneration,
                    errorCode: nil
                )
            }
            return response(result, stderrCode: nil)
        } catch PDFHighlightReaderError.unreadableDocument {
            return failure(.unreadableDocument)
        } catch PDFHighlightReaderError.pageUnavailable {
            return failure(.pageUnavailable)
        } catch PDFHighlightReaderError.invalidTraversal {
            return failure(.malformedRequest)
        } catch {
            return failure(.internalFailure)
        }
    }

    static func generationDigestBytes(_ token: String) -> [UInt8]? {
        guard token.utf8.count == generationPrefix.utf8.count + generationDigestByteCount * 2,
              token.hasPrefix(generationPrefix) else { return nil }
        let hex = token.dropFirst(generationPrefix.count)
        guard hex.utf8.allSatisfy({ byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(generationDigestByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.count == generationDigestByteCount ? bytes : nil
    }

    static func generationToken(digestBytes: [UInt8]) -> String? {
        guard digestBytes.count == generationDigestByteCount else { return nil }
        return generationPrefix + digestBytes.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func agentPreview(_ value: String?) -> (value: String?, truncated: Bool) {
        guard let value else { return (nil, false) }
        guard value.count > agentPreviewMaximumGraphemes || value.utf8.count > agentPreviewMaximumUTF8Bytes else {
            return (value, false)
        }
        var result = ""
        var graphemes = 0
        var bytes = 0
        for character in value {
            let characterBytes = character.utf8.count
            guard graphemes < agentPreviewMaximumGraphemes,
                  bytes <= agentPreviewMaximumUTF8Bytes - characterBytes else { break }
            result.append(character)
            graphemes += 1
            bytes += characterBytes
        }
        return (result, true)
    }

    private static func validate(_ request: PDFWorkerRequest) -> Bool {
        guard (1...maximumPageLimit).contains(request.limit),
              request.path.isEmpty == false,
              request.path.unicodeScalars.contains(where: { $0.value == 0 }) == false,
              request.path.utf8.count <= maximumPathUTF8Bytes else {
            return false
        }
        switch (request.continuation, request.generation) {
        case (nil, nil):
            return true
        case let (.some(continuation), .some(generation)):
            return continuation.pageIndex >= 0
                && continuation.annotationIndex >= 0
                && generationDigestBytes(generation) != nil
        case (.none, .some), (.some, .none):
            return false
        }
    }

    private static func generationToken(descriptor: Int32) throws -> String {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw PDFWorkerErrorCode.unsafeFile
        }
        let evidence = [
            "applebookscli.pdf.generation.v2",
            String(describing: metadata.st_dev),
            String(describing: metadata.st_ino),
            String(describing: metadata.st_size),
            String(describing: metadata.st_mtimespec.tv_sec),
            String(describing: metadata.st_mtimespec.tv_nsec),
        ].joined(separator: ":")
        let digest = SHA256.hash(data: Data(evidence.utf8))
        return generationPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func openValidatedPDF(path: String) throws -> ValidatedPDFWorkerFile {
        guard path.hasPrefix("/") else { throw PDFWorkerErrorCode.invalidPath }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard standardized.path == path else { throw PDFWorkerErrorCode.invalidPath }
        guard standardized.pathExtension.lowercased() == "pdf" else {
            throw PDFWorkerErrorCode.unsupportedFormat
        }

        let descriptor = open(
            standardized.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw PDFWorkerErrorCode.unsafeFile }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw PDFWorkerErrorCode.unsafeFile
        }
        return ValidatedPDFWorkerFile(
            descriptor: descriptor,
            descriptorURL: URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        )
    }

    private static func failure(_ code: PDFWorkerErrorCode) -> PDFWorkerInvocation {
        response(
            PDFWorkerResponse(
                version: version,
                status: .failure,
                mode: nil,
                summaryHighlights: nil,
                archiveHighlights: nil,
                nextTraversal: nil,
                hasMore: nil,
                generation: nil,
                errorCode: code
            ),
            stderrCode: code.rawValue
        )
    }

    private static func response(_ response: PDFWorkerResponse, stderrCode: String?) -> PDFWorkerInvocation {
        do {
            return PDFWorkerInvocation(stdout: try encoder().encode(response), stderrCode: stderrCode)
        } catch {
            let fallback = Data("{\"errorCode\":\"internalFailure\",\"status\":\"failure\",\"version\":\(version)}".utf8)
            return PDFWorkerInvocation(stdout: fallback, stderrCode: PDFWorkerErrorCode.internalFailure.rawValue)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct ValidatedPDFWorkerFile {
    let descriptor: Int32
    let descriptorURL: URL
}

extension PDFWorkerErrorCode: Error {}
