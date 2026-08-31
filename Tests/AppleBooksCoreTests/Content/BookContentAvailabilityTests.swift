import Foundation
import Testing
@testable import AppleBooksCore

@Suite("BookContentAvailabilityTests")
struct BookContentAvailabilityTests {
    @Test
    func mapsUbiquitousDownloadStatusesWithoutReadingContent() {
        #expect(probe(status: .notDownloaded).availability(at: syntheticURL) == .notDownloaded)
        #expect(probe(status: .downloaded).availability(at: syntheticURL) == .available)
        #expect(probe(status: .current).availability(at: syntheticURL) == .available)
        #expect(probe(status: .other).availability(at: syntheticURL) == .unknown)
        #expect(probe(status: nil).availability(at: syntheticURL) == .unknown)
    }

    @Test
    func localMissingMetadataFailureAndPlaceholderAreDistinct() {
        #expect(probe(isUbiquitous: false).availability(at: syntheticURL) == .available)

        let metadataFailure = BookContentAvailabilityProbe(
            fileMetadata: { _ in .node(.directory) },
            resourceMetadata: { _ in throw SyntheticError.metadata }
        )
        #expect(metadataFailure.availability(at: syntheticURL) == .unknown)

        var resourceCalls = 0
        let placeholder = BookContentAvailabilityProbe(
            fileMetadata: { _ in .node(.regular(size: 128, blocks: 0)) },
            resourceMetadata: { _ in
                resourceCalls += 1
                return .init(isUbiquitous: false, downloadingStatus: nil)
            }
        )
        #expect(placeholder.availability(at: syntheticURL) == .notDownloaded)
        #expect(resourceCalls == 0)
    }

    @Test
    func missingSymlinkAndUnsupportedNodesFailClosedBeforeResourceLookup() {
        for metadata in [
            BookContentAvailabilityProbe.FileMetadata.missing,
            .node(.symlink),
            .node(.other),
            .unknown,
        ] {
            var resourceCalls = 0
            let probe = BookContentAvailabilityProbe(
                fileMetadata: { _ in metadata },
                resourceMetadata: { _ in
                    resourceCalls += 1
                    return .init(isUbiquitous: false, downloadingStatus: nil)
                }
            )
            let result = probe.availability(at: syntheticURL)
            #expect(result == (metadata == .missing ? .missing : .unknown))
            #expect(resourceCalls == 0)
        }
    }

    @Test
    func liveMetadataRecognizesNormalLocalFileAndDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("local.xhtml")
        try Data("synthetic".utf8).write(to: file)

        #expect(BookContentAvailability.inspect(root) == .available)
        #expect(BookContentAvailability.inspect(file) == .available)
    }

    @Test
    func availabilityUsesOnlyTheTwoMetadataSeams() {
        var fileMetadataCalls = 0
        var resourceMetadataCalls = 0
        let probe = BookContentAvailabilityProbe(
            fileMetadata: { _ in
                fileMetadataCalls += 1
                return .node(.directory)
            },
            resourceMetadata: { _ in
                resourceMetadataCalls += 1
                return .init(isUbiquitous: false, downloadingStatus: nil)
            }
        )

        #expect(probe.availability(at: syntheticURL) == .available)
        #expect(fileMetadataCalls == 1)
        #expect(resourceMetadataCalls == 1)
    }

    private func probe(
        isUbiquitous: Bool = true,
        status: BookContentAvailabilityProbe.DownloadStatus? = .current
    ) -> BookContentAvailabilityProbe {
        BookContentAvailabilityProbe(
            fileMetadata: { _ in .node(.directory) },
            resourceMetadata: { _ in .init(isUbiquitous: isUbiquitous, downloadingStatus: status) }
        )
    }

    private var syntheticURL: URL {
        URL(fileURLWithPath: "/synthetic/book.epub")
    }

    private enum SyntheticError: Error {
        case metadata
    }
}
