import Darwin
import Foundation

public enum EPUBContentSource: String, Codable, Equatable, Sendable {
    case current
    case supplemental
}

struct EPUBSourceResolution {
    let currentAvailability: BookContentAvailability?
    let supplementalAvailability: BookContentAvailability?
    let selectedSource: EPUBContentSource?
    let reader: (any EPUBResourceReader)?
    let failure: Error?

    func requireReader() throws -> (source: EPUBContentSource, reader: any EPUBResourceReader) {
        if let selectedSource, let reader {
            return (selectedSource, reader)
        }
        throw failure ?? ContentError.bookPathUnavailable
    }
}

enum EPUBSourceResolver {
    static func supplementalRootIsReady(_ root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(canonicalRoot.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        return BookContentAvailability.inspect(canonicalRoot) == .available
    }

    static func reader(for book: Book, configuration: AppleBooksConfiguration) throws -> any EPUBResourceReader {
        try resolve(for: book, configuration: configuration).requireReader().reader
    }

    static func resolve(
        for book: Book,
        configuration: AppleBooksConfiguration,
        observingAvailability: Bool = false
    ) -> EPUBSourceResolution {
        guard let rawPath = book.path else {
            return EPUBSourceResolution(
                currentAvailability: nil,
                supplementalAvailability: nil,
                selectedSource: nil,
                reader: nil,
                failure: ContentError.bookPathUnavailable
            )
        }

        let currentURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        var currentAvailability: BookContentAvailability?
        let primaryError: Error
        do {
            guard currentURL.pathExtension.lowercased() == "epub" else {
                throw ContentError.unsupportedFormat
            }
            let reader = try DirectoryEPUBResourceReader(root: currentURL)
            let supplementalAvailability = observingAvailability
                ? supplementalCandidateURL(rawPath: rawPath, configuration: configuration).map(BookContentAvailability.inspect)
                : nil
            return EPUBSourceResolution(
                currentAvailability: observingAvailability ? .available : nil,
                supplementalAvailability: supplementalAvailability,
                selectedSource: .current,
                reader: reader,
                failure: nil
            )
        } catch let error as EPUBResourceError {
            let supplementalAvailability = observingAvailability
                ? supplementalCandidateURL(rawPath: rawPath, configuration: configuration).map(BookContentAvailability.inspect)
                : nil
            return EPUBSourceResolution(
                currentAvailability: observingAvailability ? BookContentAvailability.inspect(currentURL) : nil,
                supplementalAvailability: supplementalAvailability,
                selectedSource: nil,
                reader: nil,
                failure: error
            )
        } catch let error as ContentError {
            switch error {
            case let .unavailable(availability):
                currentAvailability = observingAvailability ? availability : nil
                primaryError = error
            case .unsupportedFormat:
                currentAvailability = observingAvailability ? BookContentAvailability.inspect(currentURL) : nil
                primaryError = error
            default:
                let supplementalAvailability = observingAvailability
                    ? supplementalCandidateURL(rawPath: rawPath, configuration: configuration).map(BookContentAvailability.inspect)
                    : nil
                return EPUBSourceResolution(
                    currentAvailability: observingAvailability ? BookContentAvailability.inspect(currentURL) : nil,
                    supplementalAvailability: supplementalAvailability,
                    selectedSource: nil,
                    reader: nil,
                    failure: error
                )
            }
        } catch {
            let supplementalAvailability = observingAvailability
                ? supplementalCandidateURL(rawPath: rawPath, configuration: configuration).map(BookContentAvailability.inspect)
                : nil
            return EPUBSourceResolution(
                currentAvailability: observingAvailability ? BookContentAvailability.inspect(currentURL) : nil,
                supplementalAvailability: supplementalAvailability,
                selectedSource: nil,
                reader: nil,
                failure: error
            )
        }

        let supplementalURL = supplementalCandidateURL(rawPath: rawPath, configuration: configuration)
        var supplementalAvailability = observingAvailability
            ? supplementalURL.map(BookContentAvailability.inspect)
            : nil
        guard let supplementalURL, isRegularFileWithoutFollowingSymlink(supplementalURL) else {
            return EPUBSourceResolution(
                currentAvailability: currentAvailability,
                supplementalAvailability: supplementalAvailability,
                selectedSource: nil,
                reader: nil,
                failure: primaryError
            )
        }
        do {
            let reader = try ZIPEPUBResourceReader(fileURL: supplementalURL)
            if observingAvailability { supplementalAvailability = .available }
            return EPUBSourceResolution(
                currentAvailability: currentAvailability,
                supplementalAvailability: supplementalAvailability,
                selectedSource: .supplemental,
                reader: reader,
                failure: nil
            )
        } catch let error as ContentError {
            if observingAvailability,
               case let .unavailable(availability) = error {
                supplementalAvailability = availability
            }
            return EPUBSourceResolution(
                currentAvailability: currentAvailability,
                supplementalAvailability: supplementalAvailability,
                selectedSource: nil,
                reader: nil,
                failure: error
            )
        } catch {
            return EPUBSourceResolution(
                currentAvailability: currentAvailability,
                supplementalAvailability: supplementalAvailability,
                selectedSource: nil,
                reader: nil,
                failure: error
            )
        }
    }

    private static func supplementalCandidateURL(
        rawPath: String,
        configuration: AppleBooksConfiguration
    ) -> URL? {
        guard let root = configuration.epubRoot else { return nil }
        return supplementalCandidateURL(rawPath: rawPath, root: root)
    }

    private static func supplementalCandidateURL(rawPath: String, root: URL) -> URL? {
        let basename = URL(fileURLWithPath: rawPath).lastPathComponent
        guard basename.isEmpty == false,
              basename.lowercased().hasSuffix(".epub") else {
            return nil
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(basename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == canonicalRoot else { return nil }
        return candidate
    }

    private static func isRegularFileWithoutFollowingSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }
}
