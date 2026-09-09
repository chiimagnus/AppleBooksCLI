import Foundation
import Testing
@testable import AppleBooksCore

@Suite("DatabaseDiscoveryTests")
struct DatabaseDiscoveryTests {
    @Test
    func discoversOneDatabasePerStoreAndIgnoresSidecars() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let library = try touch(fixture.paths.libraryDirectory, "BKLibrary-1.sqlite")
        _ = try touch(fixture.paths.libraryDirectory, "BKLibrary-1.sqlite-wal")
        _ = try touch(fixture.paths.libraryDirectory, "BKLibrary-1.sqlite-shm")
        try FileManager.default.createDirectory(
            at: fixture.paths.libraryDirectory.appendingPathComponent("BKLibrary-directory.sqlite", isDirectory: true),
            withIntermediateDirectories: true
        )
        let annotations = try touch(fixture.paths.annotationsDirectory, "AEAnnotation-local.sqlite")

        let result = try DatabaseDiscovery(paths: fixture.paths).discover()
        #expect(result.libraryDB == library.standardizedFileURL.resolvingSymlinksInPath())
        #expect(result.annotationsDB == annotations.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func failsClosedForMissingOrAmbiguousCandidates() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try touch(fixture.paths.annotationsDirectory, "AEAnnotation-local.sqlite")

        do {
            _ = try DatabaseDiscovery(paths: fixture.paths).discover()
            Issue.record("missing library database should fail")
        } catch let error as DatabaseDiscoveryError {
            #expect(error == .missing(.library))
        }

        _ = try touch(fixture.paths.libraryDirectory, "BKLibrary-z.sqlite")
        _ = try touch(fixture.paths.libraryDirectory, "BKLibrary-a.sqlite")
        do {
            _ = try DatabaseDiscovery(paths: fixture.paths).discover()
            Issue.record("ambiguous library databases should fail")
        } catch let error as DatabaseDiscoveryError {
            #expect(error == .ambiguous(.library, candidates: ["BKLibrary-a.sqlite", "BKLibrary-z.sqlite"]))
        }
    }

    @Test
    func streamingDiscoveryKeepsOnlyEightDeterministicAmbiguityWitnesses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = SyntheticDirectoryAccess(irrelevantCount: 100_001, matchingCount: 10_009)
        let discovery = DatabaseDiscovery(paths: fixture.paths, directoryAccess: access)

        let expected = (0..<DatabaseCandidateAccumulator.maximumWitnesses).map {
            String(format: "BKLibrary-%05d.sqlite", $0)
        }
        #expect(discovery.probe(store: .library) == .failure(.ambiguous(candidates: expected)))
        #expect(access.state.scanCalls == 1)
        #expect(access.state.visitedNames == 110_010)
        #expect(access.state.metadataChecks == 10_009)
    }

    @Test
    func candidateAccumulatorRetainsFixedWitnessStateForArbitrarilyManyCandidates() {
        var accumulator = DatabaseCandidateAccumulator()
        for value in stride(from: 50_000, through: 0, by: -1) {
            accumulator.record(String(format: "BKLibrary-%05d.sqlite", value))
        }
        #expect(accumulator.candidateCount == 2)
        #expect(accumulator.witnesses.count == DatabaseCandidateAccumulator.maximumWitnesses)
        #expect(accumulator.witnesses == (0..<8).map { String(format: "BKLibrary-%05d.sqlite", $0) })
    }

    @Test
    func defaultDiscoveryPreservesExistingSymlinkRejection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = try touch(fixture.root, "real.sqlite")
        let link = fixture.paths.libraryDirectory.appendingPathComponent("BKLibrary-link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(DatabaseDiscovery(paths: fixture.paths).probe(store: .library) == .failure(.missing))
    }

    @Test
    func overridesAreIndependentAndMayLiveElsewhere() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let autoLibrary = try touch(fixture.paths.libraryDirectory, "BKLibrary-auto.sqlite")
        let autoAnnotations = try touch(fixture.paths.annotationsDirectory, "AEAnnotation-auto.sqlite")

        let overrides = fixture.root.appendingPathComponent("overrides", isDirectory: true)
        try FileManager.default.createDirectory(at: overrides, withIntermediateDirectories: true)
        let libraryOverride = try touch(overrides, "custom-library.db")
        let annotationsOverride = try touch(overrides, "custom-annotations.db")

        let discovery = DatabaseDiscovery(paths: fixture.paths)
        let libraryOnly = try discovery.discover(libraryOverride: libraryOverride)
        #expect(libraryOnly.libraryDB == libraryOverride.standardizedFileURL.resolvingSymlinksInPath())
        #expect(libraryOnly.annotationsDB == autoAnnotations.standardizedFileURL.resolvingSymlinksInPath())

        let annotationsOnly = try discovery.discover(annotationsOverride: annotationsOverride)
        #expect(annotationsOnly.libraryDB == autoLibrary.standardizedFileURL.resolvingSymlinksInPath())
        #expect(annotationsOnly.annotationsDB == annotationsOverride.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func permissionFailureIsDistinctForDiagnosticsButPreservesDiscoveryContract() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try touch(fixture.paths.annotationsDirectory, "AEAnnotation-auto.sqlite")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.paths.libraryDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.paths.libraryDirectory.path) }

        let discovery = DatabaseDiscovery(paths: fixture.paths)
        #expect(discovery.probe(store: .library) == .failure(.permission))
        #expect(throws: DatabaseDiscoveryError.missing(.library)) {
            _ = try discovery.discover()
        }
    }

    @Test
    func overrideMustBeAReadableRegularFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try touch(fixture.paths.annotationsDirectory, "AEAnnotation-auto.sqlite")

        do {
            _ = try DatabaseDiscovery(paths: fixture.paths).discover(
                libraryOverride: fixture.root.appendingPathComponent("missing.sqlite")
            )
            Issue.record("missing override should fail")
        } catch let error as DatabaseDiscoveryError {
            #expect(error == .invalidOverride(.library))
        }

        do {
            _ = try DatabaseDiscovery(paths: fixture.paths).discover(libraryOverride: fixture.paths.libraryDirectory)
            Issue.record("directory override should fail")
        } catch let error as DatabaseDiscoveryError {
            #expect(error == .invalidOverride(.library))
        }
    }

    private func makeFixture() throws -> (root: URL, paths: AppleBooksDatabasePaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("BKLibrary", isDirectory: true)
        let annotations = root.appendingPathComponent("AEAnnotation", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        return (root, AppleBooksDatabasePaths(libraryDirectory: library, annotationsDirectory: annotations))
    }

    private struct SyntheticDirectoryAccess: DatabaseDirectoryAccess {
        final class State: @unchecked Sendable {
            var scanCalls = 0
            var visitedNames = 0
            var metadataChecks = 0
        }

        let irrelevantCount: Int
        let matchingCount: Int
        let state = State()

        func forEachEntryName(in directory: URL, _ body: (String) -> Void) throws {
            _ = directory
            state.scanCalls += 1
            for index in 0..<irrelevantCount {
                state.visitedNames += 1
                body("unrelated-\(index).txt")
            }
            for index in 0..<matchingCount {
                state.visitedNames += 1
                let value = (index * 9_973) % matchingCount
                body(String(format: "BKLibrary-%05d.sqlite", value))
            }
        }

        func isRegularVisibleFile(_ url: URL) throws -> Bool {
            _ = url
            state.metadataChecks += 1
            return true
        }
    }

    @discardableResult
    private func touch(_ directory: URL, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }
}
