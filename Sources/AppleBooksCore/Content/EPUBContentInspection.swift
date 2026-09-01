import Foundation

public enum EPUBContentUnavailableReason: String, Codable, Equatable, Sendable {
    case bookPathUnavailable
    case unsupportedFormat
    case notDownloaded
    case missing
    case unknown
    case invalidSource
    case contentEncryptionUnsupported
    case malformedEncryptionMetadata
}

public struct EPUBContentStatus: Equatable, Sendable {
    public let bookLocalPK: Int64
    public let bookAssetID: String?
    public let currentAvailability: BookContentAvailability?
    public let supplementalAvailability: BookContentAvailability?
    public let selectedSource: EPUBContentSource?
    public let materialization: BookContentAvailability
    public let encryption: EPUBEncryption?
    public let unavailableReason: EPUBContentUnavailableReason?

    public var isReady: Bool {
        selectedSource != nil && materialization == .available && unavailableReason == nil
    }
}

public struct EPUBMetadataInspection: Equatable, Sendable {
    public let book: Book
    public let source: EPUBContentSource
    public let metadata: EPUBMetadata
    public let enrichment: BookMetadataEnrichment
}

public struct EPUBCoverInspection: Equatable, Sendable {
    public let bookLocalPK: Int64
    public let bookAssetID: String?
    public let source: EPUBContentSource
    public let cover: EPUBCover
}

public struct EPUBLocationInspection: Equatable, Sendable {
    public let bookLocalPK: Int64
    public let bookAssetID: String?
    public let location: Location
    public let source: EPUBContentSource?
    public let chapter: Chapter?
}

enum EPUBContentInspector {
    static func status(book: Book, configuration: AppleBooksConfiguration) -> EPUBContentStatus {
        let resolution = EPUBSourceResolver.resolve(
            for: book,
            configuration: configuration,
            observingAvailability: true
        )
        let materialization = materialization(for: resolution)
        var encryption: EPUBEncryption?
        var unavailableReason: EPUBContentUnavailableReason?

        if let reader = resolution.reader {
            do {
                let package = try DirectoryEPUBPackage(reader: reader)
                let value = try EPUBEncryption.inspect(package: package)
                encryption = value
                switch value {
                case .none, .fontObfuscationOnly:
                    break
                case .contentEncryptionUnsupported:
                    unavailableReason = .contentEncryptionUnsupported
                case .malformedEncryptionMetadata:
                    unavailableReason = .malformedEncryptionMetadata
                }
            } catch {
                unavailableReason = reason(for: error)
            }
        } else if let contentError = resolution.failure as? ContentError {
            switch contentError {
            case .unavailable:
                unavailableReason = reason(for: materialization)
            default:
                unavailableReason = reason(for: contentError)
            }
        } else if materialization != .available {
            unavailableReason = reason(for: materialization)
        } else {
            unavailableReason = reason(for: resolution.failure)
        }

        return EPUBContentStatus(
            bookLocalPK: book.localPK,
            bookAssetID: book.assetID,
            currentAvailability: resolution.currentAvailability,
            supplementalAvailability: resolution.supplementalAvailability,
            selectedSource: resolution.selectedSource,
            materialization: materialization,
            encryption: encryption,
            unavailableReason: unavailableReason
        )
    }

    static func metadata(book: Book, configuration: AppleBooksConfiguration) throws -> EPUBMetadataInspection {
        let selected = try EPUBSourceResolver.resolve(for: book, configuration: configuration).requireReader()
        let content = try BookContent(reader: selected.reader)
        let metadata = try content.metadata()
        return EPUBMetadataInspection(
            book: book,
            source: selected.source,
            metadata: metadata,
            enrichment: metadata.supplementing(book)
        )
    }

    static func cover(book: Book, configuration: AppleBooksConfiguration) throws -> EPUBCoverInspection? {
        let selected = try EPUBSourceResolver.resolve(for: book, configuration: configuration).requireReader()
        let content = try BookContent(reader: selected.reader)
        guard let cover = try content.cover() else { return nil }
        return EPUBCoverInspection(
            bookLocalPK: book.localPK,
            bookAssetID: book.assetID,
            source: selected.source,
            cover: cover
        )
    }

    static func locate(
        rawCFI: String,
        book: Book,
        configuration: AppleBooksConfiguration
    ) throws -> EPUBLocationInspection {
        let location = Location(rawCFI: rawCFI)
        guard let chapterID = location.chapterID else {
            return EPUBLocationInspection(
                bookLocalPK: book.localPK,
                bookAssetID: book.assetID,
                location: location,
                source: nil,
                chapter: nil
            )
        }

        let selected = try EPUBSourceResolver.resolve(for: book, configuration: configuration).requireReader()
        let content = try BookContent(reader: selected.reader)
        let chapter = try CurrentReadingChapter.resolve(chapterID: chapterID, in: content)
        return EPUBLocationInspection(
            bookLocalPK: book.localPK,
            bookAssetID: book.assetID,
            location: location,
            source: selected.source,
            chapter: chapter
        )
    }

    private static func materialization(for resolution: EPUBSourceResolution) -> BookContentAvailability {
        if resolution.reader != nil { return .available }
        if let error = resolution.failure as? ContentError,
           case let .unavailable(availability) = error {
            return availability
        }
        if let supplemental = resolution.supplementalAvailability, supplemental != .missing {
            return supplemental
        }
        return resolution.currentAvailability ?? resolution.supplementalAvailability ?? .missing
    }

    private static func reason(for availability: BookContentAvailability) -> EPUBContentUnavailableReason {
        switch availability {
        case .available: .invalidSource
        case .notDownloaded: .notDownloaded
        case .missing: .missing
        case .unknown: .unknown
        }
    }

    private static func reason(for error: Error?) -> EPUBContentUnavailableReason {
        guard let error else { return .invalidSource }
        if let content = error as? ContentError {
            switch content {
            case let .unavailable(availability):
                return reason(for: availability)
            case .bookPathUnavailable:
                return .bookPathUnavailable
            case .unsupportedFormat:
                return .unsupportedFormat
            case .contentEncryptionUnsupported:
                return .contentEncryptionUnsupported
            case .malformedEncryptionMetadata:
                return .malformedEncryptionMetadata
            }
        }
        return .invalidSource
    }
}
