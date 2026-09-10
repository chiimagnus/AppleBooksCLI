import Darwin
import Foundation

public enum ExportFileWriterError: Error, Equatable, Sendable {
    case invalidOutputRoot
    case unsafeOutputRoot
    case invalidFileName
    case unsafeParent
    case unsafeDestination
    case destinationExists
    case writeFailed
}

public enum ExportFileWriteDisposition: String, Codable, Equatable, Sendable {
    case created
    case updated
}

public struct ExportFileWriteResult: Equatable, Sendable {
    public let destination: URL
    public let disposition: ExportFileWriteDisposition
}

public enum ExportFileLayout: Equatable, Sendable {
    case single(fileName: String)
    case perDocument
}

public struct ExportDirectoryWriteResult: Equatable, Sendable {
    public let documentFileCount: Int
    public let files: [URL]
}

public struct ExportFileWriter {
    package static let maximumChunkBytes = 64 * 1_024

    public let outputRoot: URL

    public init(outputRoot: URL) throws {
        guard outputRoot.isFileURL, outputRoot.path.hasPrefix("/") else {
            throw ExportFileWriterError.invalidOutputRoot
        }
        self.outputRoot = try Self.prepareOutputRoot(outputRoot)
    }

    @discardableResult
    public func write(
        _ data: Data,
        fileName: String,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportFileWriteResult {
        try writeIncrementally(fileName: fileName, overwrite: overwrite) { sink in
            try sink(data)
        }
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

    public func writeDocuments(
        _ bundle: ExportBundle,
        fileExtension: String,
        overwrite: OverwritePolicy = .never,
        render: (ExportGroup) throws -> Data
    ) throws -> ExportDirectoryWriteResult {
        var files: [URL] = []
        let count = try forEachDocument(bundle, fileExtension: fileExtension) { group, fileName in
            let data = try render(group)
            let result = try write(data, fileName: fileName, overwrite: overwrite)
            files.append(result.destination)
        }
        return ExportDirectoryWriteResult(
            documentFileCount: count,
            files: files
        )
    }

    package func writeDocumentsIncrementallyCount(
        _ bundle: ExportBundle,
        fileExtension: String,
        overwrite: OverwritePolicy = .never,
        render: (ExportGroup, _ sink: (Data) throws -> Void) throws -> Void
    ) throws -> Int {
        try forEachDocument(bundle, fileExtension: fileExtension) { group, fileName in
            _ = try writeIncrementally(fileName: fileName, overwrite: overwrite) { sink in
                try withoutActuallyEscaping(sink) { escapingSink in
                    try render(group, escapingSink)
                }
            }
        }
    }

    func forEachDocument(
        _ bundle: ExportBundle,
        fileExtension: String,
        materialize: (ExportGroup, String) throws -> Void
    ) throws -> Int {
        try Self.validateFileExtension(fileExtension)
        var count = 0
        for group in bundle.groups {
            let fileName = try Self.documentFileName(for: group, extension: fileExtension)
            try materialize(group, fileName)
            count += 1
        }
        return count
    }

    public func writeMarkdown(
        _ bundle: ExportBundle,
        layout: ExportFileLayout,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportDirectoryWriteResult {
        switch layout {
        case let .single(fileName):
            let data = Data(MarkdownAnnotationExporter.render(bundle).utf8)
            let result = try write(data, fileName: fileName, overwrite: overwrite)
            return ExportDirectoryWriteResult(
                documentFileCount: 1,
                files: [result.destination]
            )
        case .perDocument:
            return try writeDocuments(
                bundle,
                fileExtension: "md",
                overwrite: overwrite
            ) { group in
                Data(MarkdownAnnotationExporter.render(group).utf8)
            }
        }
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

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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

    private static func entryType(parentFD: Int32, name: String) throws -> mode_t? {
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

    package static func validateDestination(
        _ destination: URL,
        grouping: ExportFileGrouping,
        overwrite: OverwritePolicy
    ) throws {
        try validateFileName(destination.lastPathComponent)
        guard let type = nodeType(destination) else { return }
        if overwrite == .never { throw ExportFileWriterError.destinationExists }
        let expected = grouping == .single ? S_IFREG : S_IFDIR
        guard type == expected else { throw ExportFileWriterError.unsafeDestination }
    }

    private static func validateFileExtension(_ fileExtension: String) throws {
        guard fileExtension.isEmpty == false,
              fileExtension.count <= 16,
              fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ExportFileWriterError.invalidFileName
        }
    }

    private static func validateFileName(_ fileName: String) throws {
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

    private static func nodeType(_ url: URL) -> mode_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_mode & S_IFMT
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
