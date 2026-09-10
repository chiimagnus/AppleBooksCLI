import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ExportFileWriterTests")
struct ExportFileWriterTests {
    @Test
    func neverIsDefaultAlwaysReplacesAndAtomicWritesLeaveNoTemporaryFile() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)

        let created = try writeData(Data("first".utf8), using: writer, fileName: "report.json")
        #expect(created.disposition == .created)
        #expect(try String(contentsOf: created.destination, encoding: .utf8) == "first")
        #expect(throws: ExportFileWriterError.destinationExists) {
            _ = try writeData(Data("second".utf8), using: writer, fileName: "report.json")
        }
        #expect(try String(contentsOf: created.destination, encoding: .utf8) == "first")

        let updated = try writeData(
            Data("second".utf8),
            using: writer,
            fileName: "report.json",
            overwrite: .always
        )
        #expect(updated.disposition == .updated)
        #expect(try String(contentsOf: updated.destination, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasSuffix(".part") } == false)
    }

    @Test
    func alwaysPublishesIdenticalDataAndPreservesNewJSONTimestampBytes() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let original = Data(#"{"exportedAt":"2026-01-01T00:00:00Z","body":"same"}"#.utf8)
        let newer = Data(#"{"exportedAt":"2026-09-01T00:00:00Z","body":"same"}"#.utf8)
        let first = try writeData(original, using: writer, fileName: "export.json")
        let originalInode = try FileManager.default.attributesOfItem(atPath: first.destination.path)[.systemFileNumber] as? NSNumber
        let repeated = try writeData(original, using: writer, fileName: "export.json", overwrite: .always)
        let replacedInode = try FileManager.default.attributesOfItem(atPath: first.destination.path)[.systemFileNumber] as? NSNumber
        #expect(originalInode != nil && replacedInode != nil && originalInode != replacedInode)
        #expect(repeated.disposition == .updated)
        let updated = try writeData(newer, using: writer, fileName: "export.json", overwrite: .always)
        #expect(updated.disposition == .updated)
        #expect(try Data(contentsOf: updated.destination) == newer)
    }

    @Test
    func incrementalRenderFailureCleansTemporaryFileAndPreservesDestination() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let destination = fixture.output.appendingPathComponent("report.json")
        try Data("original".utf8).write(to: destination)

        #expect(throws: FixtureError.stopped) {
            _ = try writer.writeIncrementally(
                fileName: "report.json",
                overwrite: .always
            ) { sink in
                try sink(Data("partial".utf8))
                throw FixtureError.stopped
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasSuffix(".part") } == false)
    }

    @Test
    func descriptorRelativePublishFailsClosedAcrossParentAndDestinationRaces() throws {
        let parentFixture = try FileFixture()
        defer { parentFixture.remove() }
        let parentWriter = try ExportFileWriter(outputRoot: parentFixture.output)
        let heldOutput = parentFixture.root.appendingPathComponent("held-output", isDirectory: true)
        #expect(throws: ExportFileWriterError.unsafeParent) {
            _ = try parentWriter.writeIncrementally(
                fileName: "report.json",
                beforePublish: {
                    try FileManager.default.moveItem(at: parentFixture.output, to: heldOutput)
                    try FileManager.default.createDirectory(at: parentFixture.output, withIntermediateDirectories: false)
                }
            ) { sink in
                try sink(Data("safe".utf8))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parentFixture.output.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: heldOutput.path).contains { $0.hasSuffix(".part") } == false)

        let symlinkFixture = try FileFixture()
        defer { symlinkFixture.remove() }
        let symlinkWriter = try ExportFileWriter(outputRoot: symlinkFixture.output)
        let outside = symlinkFixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let destination = symlinkFixture.output.appendingPathComponent("report.json")
        try Data("original".utf8).write(to: destination)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try symlinkWriter.writeIncrementally(
                fileName: "report.json",
                overwrite: .always,
                beforePublish: {
                    try FileManager.default.removeItem(at: destination)
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
                }
            ) { sink in
                try sink(Data("replacement".utf8))
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")

        let competitorFixture = try FileFixture()
        defer { competitorFixture.remove() }
        let competitorWriter = try ExportFileWriter(outputRoot: competitorFixture.output)
        let competitor = competitorFixture.output.appendingPathComponent("report.json")
        #expect(throws: ExportFileWriterError.destinationExists) {
            _ = try competitorWriter.writeIncrementally(
                fileName: "report.json",
                beforePublish: {
                    try Data("competitor".utf8).write(to: competitor)
                }
            ) { sink in
                try sink(Data("ours".utf8))
            }
        }
        #expect(try String(contentsOf: competitor, encoding: .utf8) == "competitor")
    }

    @Test
    func managedDirectoryNeverPublishesOnlyCompleteTreeAndExistingTargetStaysUntouched() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 3)
        let destination = fixture.output.appendingPathComponent("managed", isDirectory: true)
        var checkedInvisibleStage = false

        let created = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json",
            beforePublish: {
                checkedInvisibleStage = true
                #expect(FileManager.default.fileExists(atPath: destination.path) == false)
            }
        ) { group, sink in
            try sink(Data("new-\(try #require(group.documentIdentity).fullKey)".utf8))
        }
        #expect(checkedInvisibleStage)
        #expect(created.documentCount == 3)
        #expect(created.cleanupFailed == false)
        let createdNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(createdNames.count == 4)
        #expect(createdNames.contains(ManagedExportManifestWriter.fileName))
        #expect(createdNames.filter { $0 != ManagedExportManifestWriter.fileName }.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasPrefix(".applebookscli-export-stage-") } == false)

        let original = try directorySnapshot(destination)
        #expect(throws: ExportFileWriterError.destinationExists) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destination.lastPathComponent,
                bundle: bundle,
                fileExtension: "json",
                overwrite: .never
            ) { _, sink in
                try sink(Data("replacement".utf8))
            }
        }
        #expect(try directorySnapshot(destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasPrefix(".applebookscli-export-stage-") } == false)
    }

    @Test
    func managedDirectoryPublishesZeroDocumentArtifactWithManifestOnly() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 0)
        let destination = fixture.output.appendingPathComponent("empty", isDirectory: true)

        let result = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { _, _ in
            Issue.record("zero-document export must not render a document")
        }

        #expect(result.documentCount == 0)
        #expect(result.cleanupFailed == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [ManagedExportManifestWriter.fileName])
    }

    @Test
    func managedDirectoryRenderFailureAtAnyPositionLeavesNoVisibleOrHiddenPartialTree() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 3)

        for stopAt in 0..<bundle.groups.count {
            let destinationName = "failed-\(stopAt)"
            var index = 0
            #expect(throws: FixtureError.stopped) {
                _ = try writer.writeManagedDirectoryIncrementally(
                    destinationName: destinationName,
                    bundle: bundle,
                    fileExtension: "md"
                ) { _, sink in
                    if index == stopAt { throw FixtureError.stopped }
                    index += 1
                    try sink(Data("partial".utf8))
                }
            }
            #expect(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent(destinationName).path) == false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasPrefix(".applebookscli-export-stage-") } == false)
        }
    }

    @Test
    func managedDirectoryAlwaysRequiresOwnedTreeAndSwapsCompleteReplacement() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 2)
        let unmanaged = fixture.output.appendingPathComponent("unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: false)
        try Data("user".utf8).write(to: unmanaged.appendingPathComponent("user.txt"))
        var rendered = false
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: unmanaged.lastPathComponent,
                bundle: bundle,
                fileExtension: "json",
                overwrite: .always
            ) { _, _ in rendered = true }
        }
        #expect(rendered == false)
        #expect(try String(contentsOf: unmanaged.appendingPathComponent("user.txt"), encoding: .utf8) == "user")

        let destination = fixture.output.appendingPathComponent("managed", isDirectory: true)
        _ = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { _, sink in try sink(Data("old".utf8)) }
        let oldSnapshot = try directorySnapshot(destination)
        var observedOldBeforeSwap = false
        let updated = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json",
            overwrite: .always,
            beforePublish: {
                observedOldBeforeSwap = true
                let visibleBeforeSwap = try directorySnapshot(destination)
                #expect(visibleBeforeSwap == oldSnapshot)
            }
        ) { _, sink in try sink(Data("new".utf8)) }
        #expect(observedOldBeforeSwap)
        #expect(updated.documentCount == 2)
        #expect(updated.cleanupFailed == false)
        let newSnapshot = try directorySnapshot(destination)
        #expect(newSnapshot != oldSnapshot)
        for (name, data) in newSnapshot where name != ManagedExportManifestWriter.fileName {
            #expect(name.hasSuffix(".json"))
            #expect(String(decoding: data, as: UTF8.self) == "new")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasPrefix(".applebookscli-export-stage-") } == false)
    }

    @Test
    func managedDirectoryRejectsUnknownEntriesAndDestinationIdentityRaceBeforeSwap() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 2)
        let destination = fixture.output.appendingPathComponent("managed", isDirectory: true)
        _ = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "md"
        ) { _, sink in try sink(Data("old".utf8)) }
        let unknown = destination.appendingPathComponent("user.txt")
        try Data("user".utf8).write(to: unknown)
        let withUnknown = try directorySnapshot(destination)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destination.lastPathComponent,
                bundle: bundle,
                fileExtension: "md",
                overwrite: .always
            ) { _, sink in try sink(Data("new".utf8)) }
        }
        #expect(try directorySnapshot(destination) == withUnknown)
        try FileManager.default.removeItem(at: unknown)

        let unknownDirectory = destination.appendingPathComponent("user-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: false)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destination.lastPathComponent,
                bundle: bundle,
                fileExtension: "md",
                overwrite: .always
            ) { _, sink in try sink(Data("new".utf8)) }
        }
        try FileManager.default.removeItem(at: unknownDirectory)

        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let unknownSymlink = destination.appendingPathComponent("user-link")
        try FileManager.default.createSymbolicLink(at: unknownSymlink, withDestinationURL: outside)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destination.lastPathComponent,
                bundle: bundle,
                fileExtension: "md",
                overwrite: .always
            ) { _, sink in try sink(Data("new".utf8)) }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
        try FileManager.default.removeItem(at: unknownSymlink)

        let moved = fixture.output.appendingPathComponent("held-old", isDirectory: true)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destination.lastPathComponent,
                bundle: bundle,
                fileExtension: "md",
                overwrite: .always,
                beforePublish: {
                    try FileManager.default.moveItem(at: destination, to: moved)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try Data("intruder".utf8).write(to: destination.appendingPathComponent("intruder.txt"))
                }
            ) { _, sink in try sink(Data("new".utf8)) }
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("intruder.txt"), encoding: .utf8) == "intruder")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(ManagedExportManifestWriter.fileName).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasPrefix(".applebookscli-export-stage-") } == false)
    }

    @Test
    func managedDirectoryRejectsReplacedStageNameWithoutPublishingOrDeletingReplacement() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 2)

        func replaceStageName() throws -> URL {
            let stageName = try #require(
                FileManager.default.contentsOfDirectory(atPath: fixture.output.path)
                    .first { name in
                        guard name.hasPrefix(".applebookscli-export-stage-") else { return false }
                        return FileManager.default.fileExists(
                            atPath: fixture.output
                                .appendingPathComponent(name, isDirectory: true)
                                .appendingPathComponent(ManagedExportManifestWriter.fileName)
                                .path
                        )
                    }
            )
            let stage = fixture.output.appendingPathComponent(stageName, isDirectory: true)
            let held = fixture.output.appendingPathComponent("held-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: stage, to: held)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            try Data("intruder".utf8).write(to: stage.appendingPathComponent("intruder.txt"))
            return stage
        }

        let missingDestination = fixture.output.appendingPathComponent("missing", isDirectory: true)
        var replacement: URL?
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: missingDestination.lastPathComponent,
                bundle: bundle,
                fileExtension: "json",
                beforePublish: { replacement = try replaceStageName() }
            ) { _, sink in
                try sink(Data("new".utf8))
            }
        }
        #expect(FileManager.default.fileExists(atPath: missingDestination.path) == false)
        #expect(try String(contentsOf: try #require(replacement).appendingPathComponent("intruder.txt"), encoding: .utf8) == "intruder")

        let managedDestination = fixture.output.appendingPathComponent("managed", isDirectory: true)
        _ = try writer.writeManagedDirectoryIncrementally(
            destinationName: managedDestination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { _, sink in
            try sink(Data("old".utf8))
        }
        let oldSnapshot = try directorySnapshot(managedDestination)
        replacement = nil
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: managedDestination.lastPathComponent,
                bundle: bundle,
                fileExtension: "json",
                overwrite: .always,
                beforePublish: { replacement = try replaceStageName() }
            ) { _, sink in
                try sink(Data("new".utf8))
            }
        }
        #expect(try directorySnapshot(managedDestination) == oldSnapshot)
        #expect(try String(contentsOf: try #require(replacement).appendingPathComponent("intruder.txt"), encoding: .utf8) == "intruder")
    }

    @Test
    func managedDirectoryCleanupFailureKeepsNewArtifactAndDoesNotDeleteReplacementManifest() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.canonicalBundle(count: 2)
        let destination = fixture.output.appendingPathComponent("managed", isDirectory: true)
        _ = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { _, sink in try sink(Data("old".utf8)) }

        let forced = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json",
            overwrite: .always,
            afterSwapBeforeCleanup: { throw FixtureError.stopped }
        ) { _, sink in try sink(Data("new-1".utf8)) }
        #expect(forced.cleanupFailed)
        #expect(try directorySnapshot(destination).values.contains(Data("new-1".utf8)))
        let forcedStage = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.output.path).first { $0.hasPrefix(".applebookscli-export-stage-") })
        try FileManager.default.removeItem(at: fixture.output.appendingPathComponent(forcedStage))

        let second = fixture.output.appendingPathComponent("managed-2", isDirectory: true)
        _ = try writer.writeManagedDirectoryIncrementally(
            destinationName: second.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { _, sink in try sink(Data("old".utf8)) }
        let replaced = try writer.writeManagedDirectoryIncrementally(
            destinationName: second.lastPathComponent,
            bundle: bundle,
            fileExtension: "json",
            overwrite: .always,
            afterSwapBeforeCleanup: {
                let stage = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.output.path).first { $0.hasPrefix(".applebookscli-export-stage-") })
                let stageURL = fixture.output.appendingPathComponent(stage, isDirectory: true)
                let manifest = stageURL.appendingPathComponent(ManagedExportManifestWriter.fileName)
                try FileManager.default.removeItem(at: manifest)
                try Data("replacement-manifest".utf8).write(to: manifest)
            }
        ) { _, sink in try sink(Data("new-2".utf8)) }
        #expect(replaced.cleanupFailed)
        #expect(try directorySnapshot(second).values.contains(Data("new-2".utf8)))
        let leftover = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.output.path).first { $0.hasPrefix(".applebookscli-export-stage-") })
        let replacementManifest = fixture.output
            .appendingPathComponent(leftover, isDirectory: true)
            .appendingPathComponent(ManagedExportManifestWriter.fileName)
        #expect(try String(contentsOf: replacementManifest, encoding: .utf8) == "replacement-manifest")
    }

    @Test
    func managedManifestStreamsHundredThousandEntriesWithBoundedRetainedLineState() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let path = fixture.output.appendingPathComponent("manifest")
        let descriptor = open(path.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        let count = 100_001
        var writePeak = 0
        var writer = try ManagedExportManifestWriter(
            descriptor: descriptor,
            fileExtension: "json",
            declaredDocumentCount: count,
            observeRetainedBytes: { writePeak = max(writePeak, $0) }
        )
        for index in 0..<count {
            let key = "doc1_" + String(format: "%064llx", UInt64(index))
            let identity = ExportDocumentIdentity(sourceKind: .epub, fullKey: key)
            try writer.append(identity: identity, fileName: "D-\(key).json")
        }
        try writer.finish()
        var readPeak = 0
        let summary = try ManagedExportManifest.validate(
            descriptor: descriptor,
            observeRetainedBytes: { readPeak = max(readPeak, $0) }
        )
        #expect(summary.declaredDocumentCount == count)
        #expect(writePeak <= ManagedExportManifestWriter.maximumLineBytes)
        #expect(readPeak <= ManagedExportManifestWriter.maximumLineBytes)
    }

    @Test
    func managedManifestRejectsMalformedOrderingSuffixCountTraversalAndOversize() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let firstKey = "doc1_" + String(repeating: "0", count: 64)
        let secondKey = "doc1_" + String(repeating: "1", count: 64)
        let validHeader = "producer\tapplebookscli\nversion\t1\nformat\tjson\ngrouping\tper-document\ncount\t2\n"
        let invalidBodies = [
            "entry\t0\t\(secondKey)\tD-\(secondKey).json\nentry\t0\t\(firstKey)\tD-\(firstKey).json\n",
            "entry\t0\t\(firstKey)\tD-\(firstKey).json\nentry\t0\t\(firstKey)\tD-\(firstKey).json\n",
            "entry\t0\t\(firstKey)\tD-wrong.json\nentry\t0\t\(secondKey)\tD-\(secondKey).json\n",
            "entry\t0\t\(firstKey)\t../D-\(firstKey).json\nentry\t0\t\(secondKey)\tD-\(secondKey).json\n",
            "entry\t0\t\(firstKey)\tD-\(firstKey).json\n",
        ]
        for (index, body) in invalidBodies.enumerated() {
            let path = fixture.output.appendingPathComponent("invalid-\(index)")
            try Data((validHeader + body).utf8).write(to: path)
            let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            #expect(throws: ExportFileWriterError.unsafeDestination) {
                _ = try ManagedExportManifest.validate(descriptor: descriptor)
            }
        }

        let oversized = fixture.output.appendingPathComponent("oversized")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let oversizedFD = open(oversized.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(oversizedFD >= 0)
        guard oversizedFD >= 0 else { return }
        defer { close(oversizedFD) }
        #expect(ftruncate(oversizedFD, off_t(ManagedExportManifestWriter.maximumBytes + 1)) == 0)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try ManagedExportManifest.validate(descriptor: oversizedFD)
        }
    }

    @Test
    func derivedNamesStaySingleComponentsBoundedAndCollisionsReceiveStableSuffixes() throws {
        let hostile = " ../A/B:C\0\n.. "
        let safe = ExportPathComponent.safe(hostile)
        #expect(safe.contains("/") == false)
        #expect(safe.contains(":") == false)
        #expect(safe.contains("\0") == false)
        #expect(safe.contains("\n") == false)
        #expect(safe.hasPrefix(".") == false)
        #expect(safe.hasSuffix(".") == false)
        #expect(safe.lengthOfBytes(using: .utf8) <= ExportPathComponent.maximumUTF8Bytes)
        #expect(ExportPathComponent.safe(".") == "%2E")
        #expect(ExportPathComponent.safe("..") == "%2E%2E")

        let long = String(repeating: "界", count: 100)
        #expect(ExportPathComponent.safe(long).lengthOfBytes(using: .utf8) <= ExportPathComponent.maximumUTF8Bytes)
    }

    @Test
    func managedPerDocumentWriterUsesStableIdentityNamesAndExtensionValidation() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let unordered = FixtureFactory.bundleWithDuplicateTitles()
        let groups = unordered.groups.sorted {
            $0.documentIdentity! < $1.documentIdentity!
        }
        let bundle = FixtureFactory.makeBundle(groups: groups)
        let destination = fixture.output.appendingPathComponent("managed", isDirectory: true)

        let result = try writer.writeManagedDirectoryIncrementally(
            destinationName: destination.lastPathComponent,
            bundle: bundle,
            fileExtension: "json"
        ) { group, sink in
            try sink(Data("records=\(group.records.count)".utf8))
        }
        let expected = try groups.map { group in
            "Same-\(try #require(group.documentIdentity).fullKey).json"
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0 != ManagedExportManifestWriter.fileName }
            .sorted()
        #expect(result.documentCount == 2)
        #expect(names == expected.sorted())
        #expect(Set(expected).count == 2)
        #expect(expected.allSatisfy { $0.utf8.count <= 200 })
        #expect(try names.map { try String(contentsOf: destination.appendingPathComponent($0), encoding: .utf8) } == ["records=1", "records=1"])

        #expect(throws: ExportFileWriterError.invalidFileName) {
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: "invalid-extension",
                bundle: bundle,
                fileExtension: "../json"
            ) { _, _ in }
        }
    }

    @Test
    func documentFilenameIsStableAcrossOrderAndSubsetAndDoesNotLeakRawIdentity() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let rawA = "private/A #?% 文档/" + String(repeating: "x", count: 2_100)
        let rawB = "private/B #?% 文档/" + String(repeating: "y", count: 2_100)
        let a = FixtureFactory.group(pk: 1, assetID: rawA, title: String(repeating: "Same", count: 100))
        let b = FixtureFactory.group(pk: 2, assetID: rawB, title: String(repeating: "Same", count: 100))

        var run = 0
        func names(_ groups: [ExportGroup]) throws -> [String: String] {
            run += 1
            let ordered = groups.sorted { $0.documentIdentity! < $1.documentIdentity! }
            let bundle = FixtureFactory.makeBundle(groups: ordered)
            let destinationName = "names-\(run)"
            let destination = fixture.output.appendingPathComponent(destinationName, isDirectory: true)
            _ = try writer.writeManagedDirectoryIncrementally(
                destinationName: destinationName,
                bundle: bundle,
                fileExtension: "md"
            ) { _, sink in
                try sink(Data("x".utf8))
            }
            let fileNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .filter { $0 != ManagedExportManifestWriter.fileName }
            var result: [String: String] = [:]
            for group in groups {
                let key = try #require(group.documentIdentity).fullKey
                guard let fileName = fileNames.first(where: { $0.hasSuffix("-\(key).md") }) else {
                    Issue.record("missing managed export filename for \(key)")
                    continue
                }
                result[key] = fileName
            }
            return result
        }

        let together = try names([a, b])
        let reversed = try names([b, a])
        let alone = try names([a])
        let aKey = try #require(a.documentIdentity).fullKey
        #expect(together == reversed)
        #expect(together[aKey] == alone[aKey])
        #expect(Set(together.values).count == 2)
        for fileName in together.values {
            #expect(fileName.utf8.count <= 200)
            #expect(fileName.contains("doc1_"))
            #expect(fileName.contains("private/") == false)
            #expect(fileName.contains("#") == false)
            #expect(fileName.contains("文档") == false)
        }
    }

    @Test
    func documentIdentityHashesExactUTF8IncrementallyAndStemTraversalIsBounded() throws {
        let raw = "A/#?%/e\u{301}/é/界"
        let key = ResolvedExportSourceKey.epubAsset(raw)
        var reference = Data("applebookscli.export.document.v1\0epub-asset\0".utf8)
        reference.append(contentsOf: raw.utf8)
        let expected = "doc1_" + SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
        #expect(try ExportDocumentIdentity.make(sourceKey: key).fullKey == expected)

        let hugeTitle = String(repeating: "Title ", count: (128 * 1_024 * 1_024 / 6) + 1)
        var stemPeak = 0
        let stem = ExportPathComponent.safe(hugeTitle, maximumUTF8Bytes: 120) {
            stemPeak = max(stemPeak, $0)
        }
        #expect(stem.utf8.count <= 120)
        #expect(stemPeak <= 120)

        let hugeIdentity = String(repeating: "z", count: 128 * 1_024 * 1_024 + 1)
        var digestPeak = 0
        let digest = try ExportDocumentIdentity.defaultDigest(for: .epubAsset(hugeIdentity)) {
            digestPeak = max(digestPeak, $0)
        }
        #expect(digest.count == 32)
        #expect(digestPeak <= 4_096)
    }

    @Test
    func traversalInvalidNamesAndSymlinkDestinationsFailClosed() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)

        for name in ["../escape.md", ".hidden", "bad:name.md", "bad/name.md", "bad\\name.md", " trailing.md "] {
            #expect(throws: ExportFileWriterError.invalidFileName) {
                _ = try writeData(Data("x".utf8), using: writer, fileName: name)
            }
        }

        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let symlink = fixture.output.appendingPathComponent("report.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writeData(Data("new".utf8), using: writer, fileName: "report.md", overwrite: .always)
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test
    func symlinkOutputRootAndAncestorsAreRejectedWithoutFollowingThem() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        let rootLink = fixture.root.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(outputRoot: rootLink)
        }
        let parentLink = fixture.root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(outputRoot: parentLink.appendingPathComponent("new-output", isDirectory: true))
        }
        let realNested = outsideDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: realNested, withIntermediateDirectories: false)
        let ancestorLink = fixture.root.appendingPathComponent("ancestor-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(
                outputRoot: ancestorLink
                    .appendingPathComponent("nested", isDirectory: true)
                    .appendingPathComponent("new-output", isDirectory: true)
            )
        }

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path)) == ["nested"])
    }

    @Test
    func destinationParsingRejectsReservedFinalComponents() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        for invalid in [".", "..", "/", "directory/.", "directory/..", ".applebookscli-export-v1"] {
            #expect(throws: ExportFileWriterError.invalidFileName) {
                _ = try ExportFileWriter.destination(path: invalid, currentDirectory: fixture.output)
            }
        }
        let relative = try ExportFileWriter.destination(path: "new", currentDirectory: fixture.output)
        #expect(relative == fixture.output.appendingPathComponent("new").standardizedFileURL)
    }

    private func writeData(
        _ data: Data,
        using writer: ExportFileWriter,
        fileName: String,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportFileWriteResult {
        try writer.writeIncrementally(fileName: fileName, overwrite: overwrite) { sink in
            try sink(data)
        }
    }

    private func directorySnapshot(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let path = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            result[name] = try Data(contentsOf: path)
        }
        return result
    }

    private enum FixtureError: Error, Equatable {
        case stopped
    }

    private final class FileFixture {
        let root: URL
        let output: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureFactory {
        static func bundle(
            title: String,
            author: String?,
            note: String = "note"
        ) -> ExportBundle {
            makeBundle(groups: [group(pk: 1, assetID: "asset-1", title: title, author: author, note: note)])
        }

        static func bundleWithDuplicateTitles() -> ExportBundle {
            makeBundle(groups: [
                group(pk: 1, assetID: "asset-1", title: "Same"),
                group(pk: 2, assetID: "asset-2", title: "Same"),
            ])
        }

        static func canonicalBundle(count: Int) -> ExportBundle {
            let groups = (0..<count).map { index in
                group(
                    pk: Int64(index + 1),
                    assetID: "managed-asset-\(index)",
                    title: "Managed"
                )
            }.sorted {
                guard let left = $0.documentIdentity, let right = $1.documentIdentity else { return false }
                return left < right
            }
            return makeBundle(groups: groups)
        }

        static func group(
            pk: Int64,
            assetID: String,
            title: String,
            author: String? = nil,
            note: String = "note"
        ) -> ExportGroup {
            let book = makeBook(pk: pk, assetID: assetID, title: title, author: author)
            return ExportGroup(
                source: .epubCurrent(book),
                records: [makeRecord(pk: pk, book: book, note: note)],
                documentIdentity: try! ExportDocumentIdentity.make(sourceKey: .epubAsset(assetID))
            )
        }

        static func makeBundle(groups: [ExportGroup]) -> ExportBundle {
            let count = groups.reduce(0) { $0 + $1.records.count }
            return ExportBundle(
                options: try! ExportOptions(source: .epub, hasHighlight: true),
                groups: groups,
                warnings: [],
                statistics: ExportStatistics(
                    documentCount: groups.count,
                    epubDocumentCount: groups.count,
                    pdfDocumentCount: 0,
                    recordCount: count,
                    epubAnnotationCount: count,
                    pdfHighlightCount: 0,
                    highlightCount: count,
                    noteCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: 0
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: groups.count,
                    epubAnnotationCount: count,
                    pdfAttemptedDocumentCount: 0,
                    pdfSucceededDocumentCount: 0,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: 0
                )
            )
        }

        private static func makeBook(pk: Int64, assetID: String, title: String, author: String?) -> Book {
            Book(
                localPK: pk,
                assetID: assetID,
                title: title,
                author: author,
                description: nil,
                epubID: nil,
                genre: nil,
                genresRaw: nil,
                comments: nil,
                language: nil,
                year: 2024,
                contentType: 1,
                pageCount: nil,
                path: nil,
                fileSize: nil,
                coverURL: nil,
                isFinished: nil,
                readingProgressRaw: nil,
                durationRawMilliseconds: nil,
                creationDate: nil,
                modificationDate: nil,
                finishedDate: nil,
                lastOpenDate: nil,
                purchaseDate: nil,
                releaseDate: nil,
                isExplicit: nil,
                isLocked: nil,
                isEphemeral: nil,
                isHidden: nil,
                isSample: nil,
                isStoreAudiobook: nil,
                rating: nil
            )
        }

        private static func makeRecord(pk: Int64, book: Book, note: String = "note") -> ExportRecord {
            let annotation = Annotation(
                localPK: pk,
                uuid: "uuid-\(pk)",
                rawAssetID: book.assetID,
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: "quote-\(pk)",
                note: note,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            return ExportRecord(payload: .epub(EnrichedAnnotation(annotation: annotation, source: .currentLibrary(book))))
        }
    }
}
