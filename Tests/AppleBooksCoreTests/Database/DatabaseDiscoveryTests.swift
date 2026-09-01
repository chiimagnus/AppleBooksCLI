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

    @discardableResult
    private func touch(_ directory: URL, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }
}
