import CryptoKit
import Darwin
import Foundation

public enum ExportFileWriterError: Error, Equatable, Sendable {
    case invalidOutputRoot
    case unsafeOutputRoot
    case invalidFileName
    case unsafeParent
    case unsafeDestination
    case destinationExists
    case unsupportedCoverMediaType
    case writeFailed
}

public enum ExportFileWriteDisposition: String, Codable, Equatable, Sendable {
    case created
    case updated
    case unchanged
}

public struct ExportFileWriteResult: Equatable, Sendable {
    public let destination: URL
    public let disposition: ExportFileWriteDisposition
    public let stableHash: String
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
    private let now: () -> Date

    public init(outputRoot: URL) throws {
        try self.init(outputRoot: outputRoot, now: Date.init)
    }

    init(
        outputRoot: URL,
        now: @escaping () -> Date
    ) throws {
        guard outputRoot.isFileURL, outputRoot.path.hasPrefix("/") else {
            throw ExportFileWriterError.invalidOutputRoot
        }
        self.outputRoot = try Self.prepareOutputRoot(outputRoot)
        self.now = now
    }

    @discardableResult
    public func write(
        _ data: Data,
        fileName: String,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportFileWriteResult {
        try writeGenerated(
            stableData: data,
            fileName: fileName,
            parent: outputRoot,
            overwrite: overwrite
        ) { _, _ in data }
    }

    public func writeDocuments(
        _ bundle: ExportBundle,
        fileExtension: String,
        overwrite: OverwritePolicy = .never,
        render: (ExportGroup) throws -> Data
    ) throws -> ExportDirectoryWriteResult {
        try Self.validateFileExtension(fileExtension)
        var allocator = ExportFilenameAllocator()
        var files: [URL] = []
        for group in bundle.groups {
            let fileName = allocator.allocate(
                derivedFrom: Self.fileStem(for: group),
                extension: fileExtension
            )
            let data = try render(group)
            let result = try write(data, fileName: fileName, overwrite: overwrite)
            files.append(result.destination)
        }
        return ExportDirectoryWriteResult(
            documentFileCount: files.count,
            files: files
        )
    }

    public func writeMarkdown(
        _ bundle: ExportBundle,
        layout: ExportFileLayout,
        coverMode: ExportCoverMode = .none,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportDirectoryWriteResult {
        var files: [URL] = []

        switch layout {
        case let .single(fileName):
            var attachmentAllocator = ExportFilenameAllocator()
            let contexts = try markdownContexts(
                groups: bundle.groups,
                coverMode: coverMode,
                overwrite: overwrite,
                attachmentAllocator: &attachmentAllocator,
                files: &files
            )
            let stable = Data(MarkdownAnnotationExporter.render(bundle, contexts: contexts).utf8)
            let result = try writeGenerated(
                stableData: stable,
                fileName: fileName,
                parent: outputRoot,
                overwrite: overwrite
            ) { _, _ in stable }
            files.append(result.destination)
            return ExportDirectoryWriteResult(
                documentFileCount: 1,
                files: files
            )

        case .perBook:
            var documentAllocator = ExportFilenameAllocator()
            var attachmentAllocator = ExportFilenameAllocator()
            let contexts = try markdownContexts(
                groups: bundle.groups,
                coverMode: coverMode,
                overwrite: overwrite,
                attachmentAllocator: &attachmentAllocator,
                files: &files
            )
            var documentFiles: [URL] = []
            for (index, group) in bundle.groups.enumerated() {
                let fileName = documentAllocator.allocate(
                    derivedFrom: Self.fileStem(for: group),
                    extension: "md"
                )
                let context = contexts[index] ?? MarkdownRenderContext()
                let stable = Data(MarkdownAnnotationExporter.render(group, context: context).utf8)
                let result = try writeGenerated(
                    stableData: stable,
                    fileName: fileName,
                    parent: outputRoot,
                    overwrite: overwrite
                ) { _, _ in stable }
                documentFiles.append(result.destination)
                files.append(result.destination)
            }
            return ExportDirectoryWriteResult(
                documentFileCount: documentFiles.count,
                files: files
            )
        }
    }

    private func markdownContexts(
        groups: [ExportGroup],
        coverMode: ExportCoverMode,
        overwrite: OverwritePolicy,
        attachmentAllocator: inout ExportFilenameAllocator,
        files: inout [URL]
    ) throws -> [Int: MarkdownRenderContext] {
        var contexts: [Int: MarkdownRenderContext] = [:]
        let attachments = coverMode == .file ? try controlledDirectory(named: "Attachments") : nil

        for (index, group) in groups.enumerated() {
            var context = MarkdownRenderContext()
            if let cover = group.epubCover {
                switch coverMode {
                case .none:
                    break
                case .inline:
                    let media = try ExportCoverMedia.resolve(cover)
                    context.cover = .inlineDataURL(
                        "data:\(media.type);base64,\(cover.data.base64EncodedString())"
                    )
                case .file:
                    guard let attachments else { throw ExportFileWriterError.writeFailed }
                    let media = try ExportCoverMedia.resolve(cover)
                    let fileName = attachmentAllocator.allocate(
                        derivedFrom: "\(Self.fileStem(for: group))-cover",
                        extension: media.extension
                    )
                    let result = try writeGenerated(
                        stableData: cover.data,
                        fileName: fileName,
                        parent: attachments,
                        overwrite: overwrite
                    ) { _, _ in cover.data }
                    files.append(result.destination)
                    context.cover = .file(relativePath: "Attachments/\(fileName)")
                }
            }
            contexts[index] = context
        }
        return contexts
    }

    private func writeGenerated(
        stableData: Data,
        fileName: String,
        parent: URL,
        overwrite: OverwritePolicy,
        materialize: (String, Date) throws -> Data
    ) throws -> ExportFileWriteResult {
        try Self.validateFileName(fileName)
        let safeParent = try validatedParent(parent)
        let destination = safeParent.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard destination.deletingLastPathComponent().path == safeParent.path else {
            throw ExportFileWriterError.unsafeDestination
        }

        let intendedHash = Self.stableHash(stableData)
        let existing = Self.nodeType(destination)
        let disposition: ExportFileWriteDisposition
        if let existing {
            guard existing == S_IFREG else { throw ExportFileWriterError.unsafeDestination }
            switch overwrite {
            case .never:
                throw ExportFileWriterError.destinationExists
            case .always:
                disposition = .updated
            case .smart:
                let current = try Data(contentsOf: destination)
                if Self.stableHash(current) == intendedHash {
                    return ExportFileWriteResult(
                        destination: destination,
                        disposition: .unchanged,
                        stableHash: intendedHash
                    )
                }
                disposition = .updated
            }
        } else {
            disposition = .created
        }

        let data = try materialize(intendedHash, now())
        try atomicWrite(data, destination: destination, parent: safeParent, creating: disposition == .created)
        return ExportFileWriteResult(
            destination: destination,
            disposition: disposition,
            stableHash: intendedHash
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

    private func controlledDirectory(named name: String) throws -> URL {
        try Self.validateFileName(name)
        let target = outputRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent().path == outputRoot.path else {
            throw ExportFileWriterError.unsafeParent
        }
        if let type = Self.nodeType(target) {
            guard type == S_IFDIR else { throw ExportFileWriterError.unsafeParent }
        } else {
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                throw ExportFileWriterError.unsafeParent
            }
        }
        return try validatedParent(target)
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

    private static func stableHash(_ data: Data) -> String {
        let normalized = normalizedStableData(data)
        return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedStableData(_ data: Data) -> Data {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            let skipped: Set<String> = [
                "last-import-hash", "last_import_hash", "exported_at", "exported", "exportedAt",
            ]
            let stable = dictionary.filter { skipped.contains($0.key) == false }
            if let normalized = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys]) {
                return normalized
            }
        }
        return data
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
