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
    case perBook
}

public struct ExportDirectoryWriteResult: Equatable, Sendable {
    public let documentFileCount: Int
    public let files: [URL]
}

public struct ExportFileWriter {
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
        try writeData(
            data,
            fileName: fileName,
            parent: outputRoot,
            overwrite: overwrite
        )
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

    package func writeDocumentsCount(
        _ bundle: ExportBundle,
        fileExtension: String,
        overwrite: OverwritePolicy = .never,
        render: (ExportGroup) throws -> Data
    ) throws -> Int {
        try forEachDocument(bundle, fileExtension: fileExtension) { group, fileName in
            _ = try write(render(group), fileName: fileName, overwrite: overwrite)
        }
    }

    func forEachDocument(
        _ bundle: ExportBundle,
        fileExtension: String,
        materialize: (ExportGroup, String) throws -> Void
    ) throws -> Int {
        try Self.validateFileExtension(fileExtension)
        var allocator = ExportFilenameAllocator()
        var count = 0
        for group in bundle.groups {
            let fileName = allocator.allocate(derivedFrom: Self.fileStem(for: group), extension: fileExtension)
            try materialize(group, fileName)
            count += 1
        }
        return count
    }

    package func writeMarkdownCount(
        _ bundle: ExportBundle,
        layout: ExportFileLayout,
        overwrite: OverwritePolicy = .never
    ) throws -> Int {
        switch layout {
        case let .single(fileName):
            let data = Data(MarkdownAnnotationExporter.render(bundle).utf8)
            _ = try write(data, fileName: fileName, overwrite: overwrite)
            return 1
        case .perBook:
            return try writeDocumentsCount(
                bundle,
                fileExtension: "md",
                overwrite: overwrite
            ) { group in
                Data(MarkdownAnnotationExporter.render(group).utf8)
            }
        }
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
        case .perBook:
            return try writeDocuments(
                bundle,
                fileExtension: "md",
                overwrite: overwrite
            ) { group in
                Data(MarkdownAnnotationExporter.render(group).utf8)
            }
        }
    }

    private func writeData(
        _ data: Data,
        fileName: String,
        parent: URL,
        overwrite: OverwritePolicy
    ) throws -> ExportFileWriteResult {
        try Self.validateFileName(fileName)
        let safeParent = try validatedParent(parent)
        let destination = safeParent.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard destination.deletingLastPathComponent().path == safeParent.path else {
            throw ExportFileWriterError.unsafeDestination
        }

        let existing = Self.nodeType(destination)
        let disposition: ExportFileWriteDisposition
        if let existing {
            if overwrite == .never { throw ExportFileWriterError.destinationExists }
            guard existing == S_IFREG else { throw ExportFileWriterError.unsafeDestination }
            disposition = .updated
        } else {
            disposition = .created
        }

        try atomicWrite(data, destination: destination, parent: safeParent, creating: disposition == .created)
        return ExportFileWriteResult(
            destination: destination,
            disposition: disposition
        )
    }

    private func atomicWrite(
        _ data: Data,
        destination: URL,
        parent: URL,
        creating: Bool
    ) throws {
        _ = try validatedParent(parent)
        let temporary = parent.appendingPathComponent(".applebookscli-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw ExportFileWriterError.writeFailed
        }
        guard Self.nodeType(temporary) == S_IFREG else { throw ExportFileWriterError.writeFailed }
        _ = try validatedParent(parent)

        let result: Int32
        if creating {
            result = renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
        } else {
            if let type = Self.nodeType(destination), type != S_IFREG {
                throw ExportFileWriterError.unsafeDestination
            }
            result = rename(temporary.path, destination.path)
        }
        guard result == 0 else {
            if creating, errno == EEXIST { throw ExportFileWriterError.destinationExists }
            throw ExportFileWriterError.writeFailed
        }
    }

    private func validatedParent(_ directory: URL) throws -> URL {
        let standardized = directory.standardizedFileURL
        guard Self.nodeType(standardized) == S_IFDIR else { throw ExportFileWriterError.unsafeParent }
        let canonical = standardized.resolvingSymlinksInPath()
        guard canonical.path == standardized.path else { throw ExportFileWriterError.unsafeParent }
        guard canonical.path == outputRoot.path || canonical.deletingLastPathComponent().path == outputRoot.path else {
            throw ExportFileWriterError.unsafeParent
        }
        return canonical
    }

    private static func prepareOutputRoot(_ raw: URL) throws -> URL {
        let standardized = raw.standardizedFileURL
        if let type = nodeType(standardized) {
            guard type == S_IFDIR else { throw ExportFileWriterError.unsafeOutputRoot }
        } else {
            let requestedParent = standardized.deletingLastPathComponent().standardizedFileURL
            guard nodeType(requestedParent) == S_IFDIR else { throw ExportFileWriterError.unsafeOutputRoot }
            let parent = requestedParent.resolvingSymlinksInPath()
            guard parent.path == requestedParent.path else { throw ExportFileWriterError.unsafeOutputRoot }
            let target = parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                throw ExportFileWriterError.unsafeOutputRoot
            }
            guard nodeType(target) == S_IFDIR else { throw ExportFileWriterError.unsafeOutputRoot }
            return target.standardizedFileURL
        }
        let canonical = standardized.resolvingSymlinksInPath()
        guard nodeType(standardized) == S_IFDIR,
              canonical.path == standardized.path else {
            throw ExportFileWriterError.unsafeOutputRoot
        }
        return canonical
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

    private static func fileStem(for group: ExportGroup) -> String {
        switch group.source {
        case let .epubCurrent(book):
            return nonEmpty(book.title) ?? nonEmpty(book.assetID) ?? "Untitled EPUB"
        case let .epubHistorical(assetID, metadata):
            return nonEmpty(metadata.title) ?? nonEmpty(assetID) ?? "Historical EPUB"
        case let .epubUnmapped(assetID):
            return nonEmpty(assetID) ?? "Unmapped EPUB"
        case let .pdf(source):
            return source.displayTitle
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else { return nil }
        return value
    }

}
