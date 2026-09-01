import Darwin
import Foundation

public enum PDFWorkerStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
}

public enum PDFWorkerErrorCode: String, Codable, Equatable, Sendable {
    case malformedRequest
    case unsupportedVersion
    case invalidPath
    case unsupportedFormat
    case unsafeFile
    case unreadableDocument
    case pageUnavailable
    case internalFailure
}

public struct PDFWorkerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let path: String

    public init(version: Int = PDFWorkerProtocol.version, path: String) {
        self.version = version
        self.path = path
    }
}

public struct PDFWorkerPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
}

public struct PDFWorkerRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct PDFWorkerColorMatch: Codable, Equatable, Sendable {
    public let color: String
    public let distance: Double
    public let isApproximate: Bool
}

public struct PDFWorkerHighlight: Codable, Equatable, Sendable {
    public let page: Int
    public let traversalIndex: Int
    public let bounds: PDFWorkerRect
    public let quadrilateralPoints: [PDFWorkerPoint]
    public let note: String?
    public let pdfKitRGBA: [Double]?
    public let presentationColor: PDFWorkerColorMatch?
    public let modifiedAt: Date?
    public let text: String?
    public let textSource: String?
    public let textIsApproximate: Bool
    public let textUnavailableReason: String?

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

public struct PDFWorkerResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let status: PDFWorkerStatus
    public let highlights: [PDFWorkerHighlight]?
    public let errorCode: PDFWorkerErrorCode?
}

public struct PDFWorkerInvocation: Equatable, Sendable {
    public let stdout: Data
    public let stderrCode: String?
}

public enum PDFWorkerProtocol {
    public static let version = 1

    public static func encodeRequest(_ request: PDFWorkerRequest) throws -> Data {
        try encoder().encode(request)
    }

    public static func decodeResponse(_ data: Data) throws -> PDFWorkerResponse {
        try decoder().decode(PDFWorkerResponse.self, from: data)
    }

    public static func run(requestData: Data) -> PDFWorkerInvocation {
        let request: PDFWorkerRequest
        do {
            request = try decoder().decode(PDFWorkerRequest.self, from: requestData)
        } catch {
            return failure(.malformedRequest)
        }
        guard request.version == version else { return failure(.unsupportedVersion) }

        let fileURL: URL
        do {
            fileURL = try validatedPDFURL(path: request.path)
        } catch let code as PDFWorkerErrorCode {
            return failure(code)
        } catch {
            return failure(.internalFailure)
        }

        do {
            let highlights = try PDFHighlightReader().read(fileURL: fileURL).map(PDFWorkerHighlight.init)
            return response(
                PDFWorkerResponse(version: version, status: .success, highlights: highlights, errorCode: nil),
                stderrCode: nil
            )
        } catch PDFHighlightReaderError.unreadableDocument {
            return failure(.unreadableDocument)
        } catch PDFHighlightReaderError.pageUnavailable {
            return failure(.pageUnavailable)
        } catch {
            return failure(.internalFailure)
        }
    }

    private static func validatedPDFURL(path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw PDFWorkerErrorCode.invalidPath }
        let rawURL = URL(fileURLWithPath: path)
        let standardized = rawURL.standardizedFileURL
        guard standardized.path == path else { throw PDFWorkerErrorCode.invalidPath }
        guard standardized.pathExtension.lowercased() == "pdf" else {
            throw PDFWorkerErrorCode.unsupportedFormat
        }

        var metadata = stat()
        guard lstat(standardized.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              access(standardized.path, R_OK) == 0 else {
            throw PDFWorkerErrorCode.unsafeFile
        }
        let canonical = standardized.resolvingSymlinksInPath()
        guard canonical.path == standardized.path else { throw PDFWorkerErrorCode.unsafeFile }
        return canonical
    }

    private static func failure(_ code: PDFWorkerErrorCode) -> PDFWorkerInvocation {
        response(
            PDFWorkerResponse(version: version, status: .failure, highlights: nil, errorCode: code),
            stderrCode: code.rawValue
        )
    }

    private static func response(_ response: PDFWorkerResponse, stderrCode: String?) -> PDFWorkerInvocation {
        do {
            return PDFWorkerInvocation(stdout: try encoder().encode(response), stderrCode: stderrCode)
        } catch {
            let fallback = Data("{\"version\":1,\"status\":\"failure\",\"errorCode\":\"internalFailure\"}".utf8)
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

extension PDFWorkerErrorCode: Error {}
