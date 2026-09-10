import Darwin
import Foundation

package enum ExportFileWriterError: Error, Equatable, Sendable {
    case invalidOutputRoot
    case unsafeOutputRoot
    case invalidFileName
    case unsafeParent
    case unsafeDestination
    case destinationExists
    case writeFailed
}

package enum ExportFileWriteDisposition: String, Codable, Equatable, Sendable {
    case created
    case updated
}

package struct ExportFileWriteResult: Equatable, Sendable {
    package let destination: URL
    package let disposition: ExportFileWriteDisposition
}

package struct ManagedExportDirectoryWriteResult: Equatable, Sendable {
    package let documentCount: Int
    package let cleanupFailed: Bool
}

private struct ManagedExistingExportDirectory {
    let directoryFD: Int32
    let manifestFD: Int32
    let directoryIdentity: (UInt64, UInt64)
    let manifestIdentity: (UInt64, UInt64)
}

package struct ManagedExportManifestSummary: Equatable, Sendable {
    let fileExtension: String
    let declaredDocumentCount: Int
}

package struct ManagedExportManifestWriter {
    package static let fileName = ".applebookscli-export-v1"
    package static let maximumBytes = 64 * 1_024 * 1_024
    package static let maximumLineBytes = 512

    private let descriptor: Int32
    private let fileExtension: String
    private let declaredDocumentCount: Int
    private let observeRetainedBytes: ((Int) -> Void)?
    private var previousIdentity: ExportDocumentIdentity?
    private var documentCount = 0
    private var byteCount = 0

    package init(
        descriptor: Int32,
        fileExtension: String,
        declaredDocumentCount: Int,
        observeRetainedBytes: ((Int) -> Void)? = nil
    ) throws {
        try ExportFileWriter.validateFileExtension(fileExtension)
        guard declaredDocumentCount >= 0 else { throw ExportFileWriterError.writeFailed }
        self.descriptor = descriptor
        self.fileExtension = fileExtension
        self.declaredDocumentCount = declaredDocumentCount
        self.observeRetainedBytes = observeRetainedBytes
        try writeLine("producer\tapplebookscli")
        try writeLine("version\t1")
        try writeLine("format\t\(fileExtension)")
        try writeLine("grouping\tper-document")
        try writeLine("count\t\(declaredDocumentCount)")
    }

    mutating func append(identity: ExportDocumentIdentity, fileName: String) throws {
        guard documentCount < declaredDocumentCount,
              previousIdentity.map({ $0 < identity }) ?? true,
              ManagedExportManifest.validFullKey(identity.fullKey),
              fileName != Self.fileName else {
            throw ExportFileWriterError.writeFailed
        }
        try ExportFileWriter.validateFileName(fileName)
        guard fileName.hasSuffix("-\(identity.fullKey).\(fileExtension)") else {
            throw ExportFileWriterError.writeFailed
        }
        try writeLine("entry\t\(identity.sourceKind.rawValue)\t\(identity.fullKey)\t\(fileName)")
        previousIdentity = identity
        documentCount += 1
    }

    package mutating func finish() throws {
        guard documentCount == declaredDocumentCount,
              fsync(descriptor) == 0 else {
            throw ExportFileWriterError.writeFailed
        }
    }

    private mutating func writeLine(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        guard data.count <= Self.maximumLineBytes,
              byteCount <= Self.maximumBytes - data.count else {
            throw ExportFileWriterError.writeFailed
        }
        observeRetainedBytes?(data.count)
        try ExportFileWriter.writeAll(data, to: descriptor)
        byteCount += data.count
    }
}

package enum ManagedExportManifest {
    package static func validate(
        descriptor: Int32,
        directoryFD: Int32? = nil,
        requireComplete: Bool = true,
        allowTrailingPartial: Bool = false,
        observeRetainedBytes: ((Int) -> Void)? = nil,
        onEntry: ((String) throws -> Void)? = nil
    ) throws -> ManagedExportManifestSummary {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(ManagedExportManifestWriter.maximumBytes),
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ExportFileWriterError.unsafeDestination
        }

        var lineNumber = 0
        var fileExtension: String?
        var declaredDocumentCount: Int?
        var parsedDocumentCount = 0
        var previousIdentity: ExportDocumentIdentity?

        try forEachLine(
            descriptor: descriptor,
            allowTrailingPartial: allowTrailingPartial,
            observeRetainedBytes: observeRetainedBytes
        ) { line in
            switch lineNumber {
            case 0:
                guard line == "producer\tapplebookscli" else { throw ExportFileWriterError.unsafeDestination }
            case 1:
                guard line == "version\t1" else { throw ExportFileWriterError.unsafeDestination }
            case 2:
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0] == "format" else { throw ExportFileWriterError.unsafeDestination }
                let value = String(fields[1])
                guard value == "md" || value == "json" else { throw ExportFileWriterError.unsafeDestination }
                fileExtension = value
            case 3:
                guard line == "grouping\tper-document" else { throw ExportFileWriterError.unsafeDestination }
            case 4:
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2,
                      fields[0] == "count",
                      let value = Int(fields[1]),
                      value >= 0 else {
                    throw ExportFileWriterError.unsafeDestination
                }
                declaredDocumentCount = value
            default:
                guard let fileExtension else { throw ExportFileWriterError.unsafeDestination }
                let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4,
                      fields[0] == "entry",
                      let rawKind = UInt8(fields[1]),
                      let sourceKind = ExportDocumentSourceKind(rawValue: rawKind) else {
                    throw ExportFileWriterError.unsafeDestination
                }
                let fullKey = String(fields[2])
                let fileName = String(fields[3])
                guard validFullKey(fullKey),
                      fileName != ManagedExportManifestWriter.fileName else {
                    throw ExportFileWriterError.unsafeDestination
                }
                do {
                    try ExportFileWriter.validateFileName(fileName)
                } catch {
                    throw ExportFileWriterError.unsafeDestination
                }
                guard fileName.hasSuffix("-\(fullKey).\(fileExtension)") else {
                    throw ExportFileWriterError.unsafeDestination
                }
                let identity = ExportDocumentIdentity(sourceKind: sourceKind, fullKey: fullKey)
                guard previousIdentity.map({ $0 < identity }) ?? true else {
                    throw ExportFileWriterError.unsafeDestination
                }
                if let directoryFD {
                    guard try ExportFileWriter.entryType(parentFD: directoryFD, name: fileName) == S_IFREG else {
                        throw ExportFileWriterError.unsafeDestination
                    }
                }
                try onEntry?(fileName)
                previousIdentity = identity
                parsedDocumentCount += 1
            }
            lineNumber += 1
        }

        guard lineNumber >= 5,
              let fileExtension,
              let declaredDocumentCount,
              requireComplete ? parsedDocumentCount == declaredDocumentCount : parsedDocumentCount <= declaredDocumentCount else {
            throw ExportFileWriterError.unsafeDestination
        }
        return ManagedExportManifestSummary(
            fileExtension: fileExtension,
            declaredDocumentCount: declaredDocumentCount
        )
    }

    fileprivate static func validFullKey(_ value: String) -> Bool {
        guard value.utf8.count == ExportDocumentIdentity.prefix.utf8.count + ExportDocumentIdentity.digestByteCount * 2,
              value.hasPrefix(ExportDocumentIdentity.prefix) else {
            return false
        }
        return value.utf8.dropFirst(ExportDocumentIdentity.prefix.utf8.count).allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func forEachLine(
        descriptor: Int32,
        allowTrailingPartial: Bool,
        observeRetainedBytes: ((Int) -> Void)?,
        body: (String) throws -> Void
    ) throws {
        var readBuffer = [UInt8](repeating: 0, count: ExportFileWriter.maximumChunkBytes)
        var lineBuffer: [UInt8] = []
        lineBuffer.reserveCapacity(ManagedExportManifestWriter.maximumLineBytes)
        while true {
            let count = readBuffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExportFileWriterError.unsafeDestination
            }
            if count == 0 { break }
            for index in 0..<count {
                let byte = readBuffer[index]
                if byte == 0x0a {
                    guard let line = String(bytes: lineBuffer, encoding: .utf8) else {
                        throw ExportFileWriterError.unsafeDestination
                    }
                    try body(line)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    guard lineBuffer.count < ManagedExportManifestWriter.maximumLineBytes else {
                        throw ExportFileWriterError.unsafeDestination
                    }
                    lineBuffer.append(byte)
                    observeRetainedBytes?(lineBuffer.count)
                }
            }
        }
        guard lineBuffer.isEmpty || allowTrailingPartial else { throw ExportFileWriterError.unsafeDestination }
    }
}

package struct ExportFileWriter {
    package static let maximumChunkBytes = 64 * 1_024

    private let outputRoot: URL

    package init(outputRoot: URL) throws {
        guard outputRoot.isFileURL, outputRoot.path.hasPrefix("/") else {
            throw ExportFileWriterError.invalidOutputRoot
        }
        self.outputRoot = try Self.prepareOutputRoot(outputRoot)
    }

    @discardableResult
    package func writeIncrementally(
        fileName: String,
        overwrite: OverwritePolicy = .never,
        beforePublish: (() throws -> Void)? = nil,
        render: (_ sink: (Data) throws -> Void) throws -> Void
    ) throws -> ExportFileWriteResult {
        try Self.validateFileName(fileName)
        let destination = outputRoot.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard destination.deletingLastPathComponent().path == outputRoot.path else {
            throw ExportFileWriterError.unsafeDestination
        }

        let parentFD = try Self.openDirectoryFD(outputRoot, createFinalIfMissing: false)
        defer { close(parentFD) }
        var parentMetadata = stat()
        guard fstat(parentFD, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFileWriterError.unsafeParent
        }

        let temporaryName = ".applebookscli-\(UUID().uuidString).part"
        let temporaryFD = openat(
            parentFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard temporaryFD >= 0 else { throw ExportFileWriterError.writeFailed }
        var temporaryExists = true
        defer {
            close(temporaryFD)
            if temporaryExists { _ = unlinkat(parentFD, temporaryName, 0) }
        }

        try render { data in
            try Self.writeAll(data, to: temporaryFD)
        }
        guard fsync(temporaryFD) == 0 else { throw ExportFileWriterError.writeFailed }
        var temporaryMetadata = stat()
        guard fstat(temporaryFD, &temporaryMetadata) == 0,
              temporaryMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ExportFileWriterError.writeFailed
        }
        try beforePublish?()
        let parentIdentity = Self.identity(parentMetadata)
        guard let displayIdentity = Self.displayDirectoryIdentity(outputRoot),
              displayIdentity.0 == parentIdentity.0,
              displayIdentity.1 == parentIdentity.1 else {
            throw ExportFileWriterError.unsafeParent
        }

        let existing = try Self.entryType(parentFD: parentFD, name: fileName)
        let disposition: ExportFileWriteDisposition
        let result: Int32
        if let existing {
            if overwrite == .never { throw ExportFileWriterError.destinationExists }
            guard existing == S_IFREG else { throw ExportFileWriterError.unsafeDestination }
            disposition = .updated
            result = renameat(parentFD, temporaryName, parentFD, fileName)
        } else {
            disposition = .created
            result = renameatx_np(parentFD, temporaryName, parentFD, fileName, UInt32(RENAME_EXCL))
        }
        guard result == 0 else {
            if errno == EEXIST { throw ExportFileWriterError.destinationExists }
            throw ExportFileWriterError.writeFailed
        }
        temporaryExists = false
        return ExportFileWriteResult(destination: destination, disposition: disposition)
    }

    package func writeManagedDirectoryIncrementally(
        destinationName: String,
        bundle: ExportBundle,
        fileExtension: String,
        overwrite: OverwritePolicy = .never,
        beforePublish: (() throws -> Void)? = nil,
        afterSwapBeforeCleanup: (() throws -> Void)? = nil,
        observeManifestRetainedBytes: ((Int) -> Void)? = nil,
        render: (ExportGroup, _ sink: (Data) throws -> Void) throws -> Void
    ) throws -> ManagedExportDirectoryWriteResult {
        try Self.validateFileName(destinationName)
        try Self.validateFileExtension(fileExtension)

        let parentFD = try Self.openDirectoryFD(outputRoot, createFinalIfMissing: false)
        defer { close(parentFD) }
        var parentMetadata = stat()
        guard fstat(parentFD, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFileWriterError.unsafeParent
        }
        let parentIdentity = Self.identity(parentMetadata)

        let existing: ManagedExistingExportDirectory?
        if overwrite == .always {
            existing = try Self.openManagedExistingDirectory(parentFD: parentFD, name: destinationName)
        } else {
            existing = nil
        }
        defer {
            if let existing {
                close(existing.manifestFD)
                close(existing.directoryFD)
            }
        }

        let stageName = ".applebookscli-export-stage-\(UUID().uuidString.lowercased())"
        guard mkdirat(parentFD, stageName, 0o700) == 0 else {
            throw ExportFileWriterError.writeFailed
        }
        let stageFD = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stageFD >= 0 else {
            _ = unlinkat(parentFD, stageName, AT_REMOVEDIR)
            throw ExportFileWriterError.writeFailed
        }
        defer { close(stageFD) }
        guard let stageIdentity = Self.descriptorIdentity(stageFD) else {
            throw ExportFileWriterError.writeFailed
        }

        let manifestFD = openat(
            stageFD,
            ManagedExportManifestWriter.fileName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard manifestFD >= 0 else {
            _ = unlinkat(parentFD, stageName, AT_REMOVEDIR)
            throw ExportFileWriterError.writeFailed
        }
        defer { close(manifestFD) }

        var stageOwnedByName = true
        defer {
            if stageOwnedByName {
                Self.cleanupUnpublishedStage(
                    parentFD: parentFD,
                    stageName: stageName,
                    stageIdentity: stageIdentity,
                    stageFD: stageFD,
                    manifestFD: manifestFD
                )
            }
        }

        var manifest = try ManagedExportManifestWriter(
            descriptor: manifestFD,
            fileExtension: fileExtension,
            declaredDocumentCount: bundle.groups.count,
            observeRetainedBytes: observeManifestRetainedBytes
        )
        for group in bundle.groups {
            guard let documentIdentity = group.documentIdentity else {
                throw ExportFileWriterError.writeFailed
            }
            let fileName = try Self.documentFileName(for: group, extension: fileExtension)
            try Self.writeStagedDocument(
                stageFD: stageFD,
                fileName: fileName,
                render: { sink in
                    try withoutActuallyEscaping(sink) { escapingSink in
                        try render(group, escapingSink)
                    }
                }
            )
            do {
                try manifest.append(identity: documentIdentity, fileName: fileName)
            } catch {
                _ = unlinkat(stageFD, fileName, 0)
                throw error
            }
        }
        try manifest.finish()
        guard fsync(stageFD) == 0 else { throw ExportFileWriterError.writeFailed }

        try beforePublish?()
        guard let displayIdentity = Self.displayDirectoryIdentity(outputRoot),
              displayIdentity.0 == parentIdentity.0,
              displayIdentity.1 == parentIdentity.1 else {
            throw ExportFileWriterError.unsafeParent
        }
        guard try Self.entryIdentity(parentFD: parentFD, name: stageName).map({
            $0.0 == stageIdentity.0 && $0.1 == stageIdentity.1
        }) == true else {
            throw ExportFileWriterError.unsafeDestination
        }

        if let existing {
            guard let currentIdentity = try Self.entryIdentity(parentFD: parentFD, name: destinationName),
                  currentIdentity.0 == existing.directoryIdentity.0,
                  currentIdentity.1 == existing.directoryIdentity.1 else {
                throw ExportFileWriterError.unsafeDestination
            }
            try Self.validateHeldManagedDirectory(existing)
            guard renameatx_np(
                parentFD,
                stageName,
                parentFD,
                destinationName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw ExportFileWriterError.writeFailed
            }
            stageOwnedByName = false
            guard fsync(parentFD) == 0 else { throw ExportFileWriterError.writeFailed }

            guard let swappedIdentity = try Self.entryIdentity(parentFD: parentFD, name: stageName),
                  swappedIdentity.0 == existing.directoryIdentity.0,
                  swappedIdentity.1 == existing.directoryIdentity.1 else {
                _ = renameatx_np(parentFD, stageName, parentFD, destinationName, UInt32(RENAME_SWAP))
                _ = fsync(parentFD)
                throw ExportFileWriterError.unsafeDestination
            }

            var cleanupFailed = false
            do {
                try afterSwapBeforeCleanup?()
                try Self.cleanupManagedOldDirectory(
                    parentFD: parentFD,
                    stageName: stageName,
                    existing: existing
                )
            } catch {
                cleanupFailed = true
            }
            return ManagedExportDirectoryWriteResult(
                documentCount: bundle.groups.count,
                cleanupFailed: cleanupFailed
            )
        }

        let publish = renameatx_np(
            parentFD,
            stageName,
            parentFD,
            destinationName,
            UInt32(RENAME_EXCL)
        )
        guard publish == 0 else {
            if errno == EEXIST { throw ExportFileWriterError.destinationExists }
            throw ExportFileWriterError.writeFailed
        }
        stageOwnedByName = false
        guard fsync(parentFD) == 0 else { throw ExportFileWriterError.writeFailed }
        return ManagedExportDirectoryWriteResult(
            documentCount: bundle.groups.count,
            cleanupFailed: false
        )
    }

    private static func openManagedExistingDirectory(
        parentFD: Int32,
        name: String
    ) throws -> ManagedExistingExportDirectory? {
        var namedMetadata = stat()
        if fstatat(parentFD, name, &namedMetadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ExportFileWriterError.unsafeDestination
        }
        guard namedMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFileWriterError.unsafeDestination
        }

        let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ExportFileWriterError.unsafeDestination }
        var ownsDirectory = true
        defer { if ownsDirectory { close(directoryFD) } }

        var directoryMetadata = stat()
        guard fstat(directoryFD, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExportFileWriterError.unsafeDestination
        }
        let namedIdentity = identity(namedMetadata)
        let directoryIdentity = identity(directoryMetadata)
        guard namedIdentity.0 == directoryIdentity.0,
              namedIdentity.1 == directoryIdentity.1 else {
            throw ExportFileWriterError.unsafeDestination
        }

        let manifestFD = openat(
            directoryFD,
            ManagedExportManifestWriter.fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard manifestFD >= 0 else { throw ExportFileWriterError.unsafeDestination }
        var ownsManifest = true
        defer { if ownsManifest { close(manifestFD) } }

        var manifestMetadata = stat()
        guard fstat(manifestFD, &manifestMetadata) == 0,
              manifestMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ExportFileWriterError.unsafeDestination
        }
        let manifestIdentity = identity(manifestMetadata)
        guard try entryIdentity(parentFD: directoryFD, name: ManagedExportManifestWriter.fileName).map({
            $0.0 == manifestIdentity.0 && $0.1 == manifestIdentity.1
        }) == true else {
            throw ExportFileWriterError.unsafeDestination
        }

        let existing = ManagedExistingExportDirectory(
            directoryFD: directoryFD,
            manifestFD: manifestFD,
            directoryIdentity: directoryIdentity,
            manifestIdentity: manifestIdentity
        )
        try validateHeldManagedDirectory(existing)

        ownsManifest = false
        ownsDirectory = false
        return existing
    }

    private static func validateHeldManagedDirectory(
        _ existing: ManagedExistingExportDirectory
    ) throws {
        guard try entryIdentity(
            parentFD: existing.directoryFD,
            name: ManagedExportManifestWriter.fileName
        ).map({
            $0.0 == existing.manifestIdentity.0 && $0.1 == existing.manifestIdentity.1
        }) == true else {
            throw ExportFileWriterError.unsafeDestination
        }
        let summary = try ManagedExportManifest.validate(
            descriptor: existing.manifestFD,
            directoryFD: existing.directoryFD
        )
        guard summary.declaredDocumentCount < Int.max,
              try managedDirectoryEntryCount(existing.directoryFD) == summary.declaredDocumentCount + 1 else {
            throw ExportFileWriterError.unsafeDestination
        }
    }

    private static func writeStagedDocument(
        stageFD: Int32,
        fileName: String,
        render: (_ sink: (Data) throws -> Void) throws -> Void
    ) throws {
        try validateFileName(fileName)
        let descriptor = openat(
            stageFD,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw ExportFileWriterError.writeFailed }
        var keepFile = false
        defer {
            close(descriptor)
            if !keepFile { _ = unlinkat(stageFD, fileName, 0) }
        }

        try render { data in
            try writeAll(data, to: descriptor)
        }
        guard fsync(descriptor) == 0 else { throw ExportFileWriterError.writeFailed }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ExportFileWriterError.writeFailed
        }
        keepFile = true
    }

    private static func cleanupUnpublishedStage(
        parentFD: Int32,
        stageName: String,
        stageIdentity: (UInt64, UInt64),
        stageFD: Int32,
        manifestFD: Int32
    ) {
        _ = try? ManagedExportManifest.validate(
            descriptor: manifestFD,
            requireComplete: false,
            allowTrailingPartial: true,
            onEntry: { fileName in
                if try entryType(parentFD: stageFD, name: fileName) == S_IFREG {
                    guard unlinkat(stageFD, fileName, 0) == 0 else {
                        throw ExportFileWriterError.writeFailed
                    }
                }
            }
        )
        if let manifestIdentity = descriptorIdentity(manifestFD),
           (try? entryIdentity(parentFD: stageFD, name: ManagedExportManifestWriter.fileName))?.map({
               $0.0 == manifestIdentity.0 && $0.1 == manifestIdentity.1
           }) == true {
            _ = unlinkat(stageFD, ManagedExportManifestWriter.fileName, 0)
        }
        if (try? entryIdentity(parentFD: parentFD, name: stageName))?.map({
            $0.0 == stageIdentity.0 && $0.1 == stageIdentity.1
        }) == true {
            _ = unlinkat(parentFD, stageName, AT_REMOVEDIR)
        }
    }

    private static func cleanupManagedOldDirectory(
        parentFD: Int32,
        stageName: String,
        existing: ManagedExistingExportDirectory
    ) throws {
        _ = try ManagedExportManifest.validate(
            descriptor: existing.manifestFD,
            directoryFD: existing.directoryFD,
            onEntry: { fileName in
                guard unlinkat(existing.directoryFD, fileName, 0) == 0 else {
                    throw ExportFileWriterError.writeFailed
                }
            }
        )
        guard try directoryEntryCount(existing.directoryFD) == 1,
              try entryIdentity(parentFD: existing.directoryFD, name: ManagedExportManifestWriter.fileName).map({
                  $0.0 == existing.manifestIdentity.0 && $0.1 == existing.manifestIdentity.1
              }) == true else {
            throw ExportFileWriterError.unsafeDestination
        }
        guard unlinkat(existing.directoryFD, ManagedExportManifestWriter.fileName, 0) == 0,
              try directoryEntryCount(existing.directoryFD) == 0,
              fsync(existing.directoryFD) == 0,
              try entryIdentity(parentFD: parentFD, name: stageName).map({
                  $0.0 == existing.directoryIdentity.0 && $0.1 == existing.directoryIdentity.1
              }) == true,
              unlinkat(parentFD, stageName, AT_REMOVEDIR) == 0,
              fsync(parentFD) == 0 else {
            throw ExportFileWriterError.writeFailed
        }
    }

    private static func managedDirectoryEntryCount(_ directoryFD: Int32) throws -> Int {
        var count = 0
        try forEachDirectoryEntryName(directoryFD) { name in
            guard try entryType(parentFD: directoryFD, name: name) == S_IFREG else {
                throw ExportFileWriterError.unsafeDestination
            }
            count += 1
        }
        return count
    }

    private static func directoryEntryCount(_ directoryFD: Int32) throws -> Int {
        var count = 0
        try forEachDirectoryEntryName(directoryFD) { _ in count += 1 }
        return count
    }

    private static func forEachDirectoryEntryName(
        _ directoryFD: Int32,
        body: (String) throws -> Void
    ) throws {
        let enumerationFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard enumerationFD >= 0 else { throw ExportFileWriterError.writeFailed }
        guard let directory = fdopendir(enumerationFD) else {
            close(enumerationFD)
            throw ExportFileWriterError.writeFailed
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ExportFileWriterError.writeFailed }
                break
            }
            var rawName = entry.pointee.d_name
            let rawNameCapacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: rawNameCapacity) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            try body(name)
        }
    }

    private static func entryIdentity(parentFD: Int32, name: String) throws -> (UInt64, UInt64)? {
        var metadata = stat()
        if fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return identity(metadata)
        }
        if errno == ENOENT { return nil }
        throw ExportFileWriterError.writeFailed
    }

    private static func descriptorIdentity(_ descriptor: Int32) -> (UInt64, UInt64)? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return nil }
        return identity(metadata)
    }

    private static func prepareOutputRoot(_ raw: URL) throws -> URL {
        let standardized = raw.standardizedFileURL
        let descriptor: Int32
        do {
            descriptor = try openDirectoryFD(standardized, createFinalIfMissing: true)
        } catch {
            throw ExportFileWriterError.unsafeOutputRoot
        }
        close(descriptor)
        return standardized
    }

    private static func openDirectoryFD(_ directory: URL, createFinalIfMissing: Bool) throws -> Int32 {
        let standardized = authorizationURL(for: directory.standardizedFileURL)
        guard standardized.isFileURL,
              standardized.path.hasPrefix("/"),
              standardized.path != "/" else {
            throw ExportFileWriterError.unsafeOutputRoot
        }
        let components = standardized.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.isEmpty == false else { throw ExportFileWriterError.unsafeOutputRoot }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExportFileWriterError.unsafeOutputRoot }
        var ownsDescriptor = true
        defer { if ownsDescriptor { close(descriptor) } }

        for (index, rawComponent) in components.enumerated() {
            let component = String(rawComponent)
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0,
               errno == ENOENT,
               createFinalIfMissing,
               index == components.index(before: components.endIndex) {
                guard mkdirat(descriptor, component, 0o755) == 0 || errno == EEXIST else {
                    throw ExportFileWriterError.unsafeOutputRoot
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw ExportFileWriterError.unsafeOutputRoot }
            close(descriptor)
            descriptor = next
        }
        ownsDescriptor = false
        return descriptor
    }

    private static func authorizationURL(for directory: URL) -> URL {
        let path = directory.path
        if path == "/var" || path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        return directory
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = min(maximumChunkBytes, rawBuffer.count - offset)
                let written = Darwin.write(descriptor, base.advanced(by: offset), count)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ExportFileWriterError.writeFailed
                }
                guard written > 0 else { throw ExportFileWriterError.writeFailed }
                offset += written
            }
        }
    }

    fileprivate static func entryType(parentFD: Int32, name: String) throws -> mode_t? {
        var metadata = stat()
        if fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return metadata.st_mode & S_IFMT
        }
        if errno == ENOENT { return nil }
        throw ExportFileWriterError.writeFailed
    }

    private static func identity(_ metadata: stat) -> (UInt64, UInt64) {
        (UInt64(bitPattern: Int64(metadata.st_dev)), UInt64(metadata.st_ino))
    }

    private static func displayDirectoryIdentity(_ directory: URL) -> (UInt64, UInt64)? {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return identity(metadata)
    }

    package static func destination(path: String, currentDirectory: URL) throws -> URL {
        guard currentDirectory.isFileURL,
              currentDirectory.path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }),
              let component = path.split(separator: "/").last else {
            throw ExportFileWriterError.invalidFileName
        }
        try validateFileName(String(component))
        let destination = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : currentDirectory.appendingPathComponent(path).standardizedFileURL
        try validateFileName(destination.lastPathComponent)
        return destination
    }

    fileprivate static func validateFileExtension(_ fileExtension: String) throws {
        guard fileExtension.isEmpty == false,
              fileExtension.count <= 16,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ExportFileWriterError.invalidFileName
        }
    }

    fileprivate static func validateFileName(_ fileName: String) throws {
        guard fileName.isEmpty == false,
              fileName != ".",
              fileName != "..",
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.first != ".",
              fileName.first != " ",
              fileName.last != ".",
              fileName.last != " ",
              fileName.lengthOfBytes(using: .utf8) <= 200,
              fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false,
              fileName.contains("/") == false,
              fileName.contains("\\") == false,
              fileName.contains(":") == false else {
            throw ExportFileWriterError.invalidFileName
        }
    }

    private static func documentFileName(for group: ExportGroup, extension fileExtension: String) throws -> String {
        guard let identity = group.documentIdentity else { throw ExportFileWriterError.writeFailed }
        let suffix = "-\(identity.fullKey).\(fileExtension)"
        let stemBudget = 200 - suffix.utf8.count
        guard stemBudget > 0 else { throw ExportFileWriterError.invalidFileName }
        let stem = ExportPathComponent.safe(
            displayStem(for: group),
            maximumUTF8Bytes: min(ExportPathComponent.maximumUTF8Bytes, stemBudget)
        )
        return stem + suffix
    }

    private static func displayStem(for group: ExportGroup) -> String {
        switch group.source {
        case let .epubCurrent(book):
            return nonEmpty(book.title) ?? "EPUB"
        case let .epubHistorical(_, metadata):
            return nonEmpty(metadata.title) ?? "Historical EPUB"
        case .epubUnmapped:
            return "Unmapped EPUB"
        case let .pdf(source):
            return nonEmpty(source.displayTitle) ?? "PDF"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else { return nil }
        return value
    }

}
