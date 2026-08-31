import Darwin
import Foundation

public enum BookContentAvailability: Equatable, Sendable {
    case available
    case notDownloaded
    case missing
    case unknown

    public static func inspect(_ url: URL) -> BookContentAvailability {
        BookContentAvailabilityProbe.live().availability(at: url)
    }
}

struct BookContentAvailabilityProbe {
    enum Node: Equatable {
        case regular(size: Int64, blocks: Int64)
        case directory
        case symlink
        case other
    }

    enum FileMetadata: Equatable {
        case node(Node)
        case missing
        case unknown
    }

    enum DownloadStatus: Equatable {
        case notDownloaded
        case downloaded
        case current
        case other
    }

    struct ResourceMetadata: Equatable {
        let isUbiquitous: Bool
        let downloadingStatus: DownloadStatus?
    }

    let fileMetadata: (URL) -> FileMetadata
    let resourceMetadata: (URL) throws -> ResourceMetadata

    func availability(at url: URL) -> BookContentAvailability {
        switch fileMetadata(url) {
        case .missing:
            return .missing
        case .unknown, .node(.symlink), .node(.other):
            return .unknown
        case let .node(.regular(size, blocks)) where size > 0 && blocks == 0:
            return .notDownloaded
        case .node(.regular), .node(.directory):
            break
        }

        let metadata: ResourceMetadata
        do {
            metadata = try resourceMetadata(url)
        } catch {
            return .unknown
        }

        guard metadata.isUbiquitous else {
            return .available
        }
        switch metadata.downloadingStatus {
        case .notDownloaded:
            return .notDownloaded
        case .downloaded, .current:
            return .available
        case .other, nil:
            return .unknown
        }
    }

    static func live() -> BookContentAvailabilityProbe {
        BookContentAvailabilityProbe(
            fileMetadata: { url in
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
            }

            switch value.st_mode & S_IFMT {
            case S_IFREG:
                return .node(.regular(size: Int64(value.st_size), blocks: Int64(value.st_blocks)))
            case S_IFDIR:
                return .node(.directory)
            case S_IFLNK:
                return .node(.symlink)
            default:
                return .node(.other)
            }
        },
            resourceMetadata: { url in
                let values = try url.resourceValues(forKeys: [
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ])
                guard let isUbiquitous = values.isUbiquitousItem else {
                    throw MetadataError.incomplete
                }
                guard isUbiquitous else {
                    return ResourceMetadata(isUbiquitous: false, downloadingStatus: nil)
                }

                let status: DownloadStatus?
                if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    status = .notDownloaded
                } else if values.ubiquitousItemDownloadingStatus == .downloaded {
                    status = .downloaded
                } else if values.ubiquitousItemDownloadingStatus == .current {
                    status = .current
                } else if values.ubiquitousItemDownloadingStatus != nil {
                    status = .other
                } else {
                    status = nil
                }
                return ResourceMetadata(isUbiquitous: true, downloadingStatus: status)
            }
        )
    }

    private enum MetadataError: Error {
        case incomplete
    }
}
