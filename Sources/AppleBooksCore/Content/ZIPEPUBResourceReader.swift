import Darwin
import Foundation
import ZIPFoundation

final class ZIPEPUBResourceReader: EPUBResourceReader {
    static let maximumEntryCount = 20_000

    private let archive: Archive
    private let entries: [String: Entry]

    init(fileURL: URL, maximumEntryCount: Int = ZIPEPUBResourceReader.maximumEntryCount) throws {
        guard maximumEntryCount > 0 else { throw EPUBResourceError.tooManyEntries }
        let canonicalURL = fileURL.standardizedFileURL
        guard canonicalURL.pathExtension.lowercased() == "epub" else {
            throw ContentError.unsupportedFormat
        }
        let availability = BookContentAvailability.inspect(canonicalURL)
        guard availability == .available else { throw ContentError.unavailable(availability) }

        let descriptor = open(canonicalURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw EPUBResourceError.unsafeResource }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw EPUBResourceError.unsafeResource
        }

        do {
            archive = try Archive(
                url: URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                accessMode: .read
            )
        } catch {
            throw EPUBResourceError.invalidArchive
        }

        var indexed: [String: Entry] = [:]
        var count = 0
        for entry in archive {
            count += 1
            guard count <= maximumEntryCount else { throw EPUBResourceError.tooManyEntries }
            switch entry.type {
            case .symlink:
                throw EPUBResourceError.unsafeResource
            case .directory:
                throw EPUBResourceError.unsafeResource
            case .file:
                let normalized = try Self.normalizedEntryPath(entry.path, directory: false)
                guard indexed[normalized] == nil else { throw EPUBResourceError.ambiguousResource }
                indexed[normalized] = entry
            }
        }
        entries = indexed
    }

    func contains(_ path: EPUBPath) throws -> Bool {
        entries[path.relativePath] != nil
    }

    func readExactResource(_ path: EPUBPath, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw EPUBResourceError.invalidByteBudget }
        guard let entry = entries[path.relativePath] else { throw EPUBResourceError.missingResource }
        guard entry.uncompressedSize <= UInt64(maxBytes) else { throw EPUBResourceError.resourceTooLarge }

        var output = Data()
        do {
            _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false) { chunk in
                guard chunk.count <= maxBytes - output.count else {
                    throw EPUBResourceError.resourceTooLarge
                }
                output.append(chunk)
            }
        } catch let error as EPUBResourceError {
            throw error
        } catch {
            throw EPUBResourceError.unreadableResource
        }
        return output
    }

    private static func normalizedEntryPath(_ rawPath: String, directory: Bool) throws -> String {
        guard rawPath.isEmpty == false,
              rawPath.contains("\0") == false,
              rawPath.contains("\\") == false,
              rawPath.hasPrefix("/") == false else {
            throw EPUBResourceError.unsafeResource
        }

        var value = rawPath
        if directory, value.hasSuffix("/") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.isEmpty == false,
              components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            throw EPUBResourceError.unsafeResource
        }
        return components.joined(separator: "/")
    }
}
