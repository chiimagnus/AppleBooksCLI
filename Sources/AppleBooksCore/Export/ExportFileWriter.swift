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
    case archiveDestinationExists
    case archivePublishFailed
    case completeArchiveRequiresStaging
    case writeFailed
}

public enum ExportFileWriteDisposition: String, Codable, Equatable, Sendable {
    case created
    case updated
    case unchanged
}

public enum ExportFileWriteWarning: Equatable, Sendable {
    case authorPageFailed
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
    public let warnings: [ExportFileWriteWarning]
}

public struct ExportFileWriter {
    public let outputRoot: URL
    private let now: () -> Date
    private let permitsCompleteArchivePerBookWrites: Bool

    public init(outputRoot: URL) throws {
        try self.init(outputRoot: outputRoot, now: Date.init)
    }

    init(
        outputRoot: URL,
        now: @escaping () -> Date,
        permitsCompleteArchivePerBookWrites: Bool = false
    ) throws {
        guard outputRoot.isFileURL, outputRoot.path.hasPrefix("/") else {
            throw ExportFileWriterError.invalidOutputRoot
        }
        self.outputRoot = try Self.prepareOutputRoot(outputRoot)
        self.now = now
        self.permitsCompleteArchivePerBookWrites = permitsCompleteArchivePerBookWrites
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
        if ExportSafetyValidator.requiresCompleteNoteArchiveValidation(bundle.options),
           permitsCompleteArchivePerBookWrites == false {
            throw ExportFileWriterError.completeArchiveRequiresStaging
        }
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
            files: files,
            warnings: []
        )
    }

    public static func writeCompleteNoteArchiveDocuments(
        _ bundle: ExportBundle,
        to destinationDirectory: URL,
        fileExtension: String,
        render: (ExportGroup) throws -> Data
    ) throws -> ExportDirectoryWriteResult {
        guard ExportSafetyValidator.requiresCompleteNoteArchiveValidation(bundle.options) else {
            throw ExportSafetyValidationError.incompleteArchiveDataset
        }
        return try publishArchiveDirectory(
            to: destinationDirectory,
            expectedDocuments: bundle.groups.count,
            now: Date.init,
            beforeArchiveRename: nil
        ) { writer in
            try writer.writeDocuments(
                bundle,
                fileExtension: fileExtension,
                overwrite: .never,
                render: render
            )
        }
    }

    public static func writeCompleteNoteArchiveMarkdown(
        _ bundle: ExportBundle,
        to destinationDirectory: URL,
        profile: MarkdownProfile = .plain,
        coverMode: ExportCoverMode = .none
    ) throws -> ExportDirectoryWriteResult {
        try writeCompleteNoteArchiveMarkdown(
            bundle,
            to: destinationDirectory,
            layout: .perBook,
            profile: profile,
            coverMode: coverMode,
            now: Date.init,
            beforeArchiveRename: nil
        )
    }

    public static func writeCompleteNoteArchiveMarkdown(
        _ bundle: ExportBundle,
        to destinationDirectory: URL,
        layout: ExportFileLayout,
        profile: MarkdownProfile = .plain,
        coverMode: ExportCoverMode = .none
    ) throws -> ExportDirectoryWriteResult {
        try writeCompleteNoteArchiveMarkdown(
            bundle,
            to: destinationDirectory,
            layout: layout,
            profile: profile,
            coverMode: coverMode,
            now: Date.init,
            beforeArchiveRename: nil
        )
    }

    static func writeCompleteNoteArchiveMarkdown(
        _ bundle: ExportBundle,
        to destinationDirectory: URL,
        layout: ExportFileLayout = .perBook,
        profile: MarkdownProfile,
        coverMode: ExportCoverMode,
        now: @escaping () -> Date,
        beforeArchiveRename: (() throws -> Void)?
    ) throws -> ExportDirectoryWriteResult {
        guard ExportSafetyValidator.requiresCompleteNoteArchiveValidation(bundle.options) else {
            throw ExportSafetyValidationError.incompleteArchiveDataset
        }
        let expectedDocuments: Int
        switch layout {
        case .single:
            expectedDocuments = 1
        case .perBook:
            expectedDocuments = bundle.groups.count
        }
        return try publishArchiveDirectory(
            to: destinationDirectory,
            expectedDocuments: expectedDocuments,
            now: now,
            beforeArchiveRename: beforeArchiveRename
        ) { writer in
            try writer.writeMarkdown(
                bundle,
                layout: layout,
                profile: profile,
                coverMode: coverMode,
                overwrite: .never
            )
        }
    }

    static func publishArchiveDirectory(
        to destinationDirectory: URL,
        expectedDocuments: Int,
        now: @escaping () -> Date,
        beforeArchiveRename: (() throws -> Void)?,
        materialize: (ExportFileWriter) throws -> ExportDirectoryWriteResult
    ) throws -> ExportDirectoryWriteResult {
        let destination = try validatedArchiveDestination(destinationDirectory)
        let staging = try createArchiveStaging(parent: destination.parent)
        var published = false
        defer {
            if published == false {
                removeControlledArchiveStaging(staging, parent: destination.parent)
            }
        }

        let stagingWriter = try ExportFileWriter(
            outputRoot: staging,
            now: now,
            permitsCompleteArchivePerBookWrites: true
        )
        let staged = try materialize(stagingWriter)
        try ExportSafetyValidator.validateMaterialization(
            expectedDocuments: expectedDocuments,
            actualDocuments: staged.documentFileCount
        )
        let publishedFiles = try staged.files.map { file -> URL in
            let prefix = staging.path + "/"
            guard file.path.hasPrefix(prefix) else { throw ExportFileWriterError.archivePublishFailed }
            let relative = String(file.path.dropFirst(prefix.count))
            guard relative.isEmpty == false else { throw ExportFileWriterError.archivePublishFailed }
            let published = destination.final.appendingPathComponent(relative).standardizedFileURL
            guard published.path.hasPrefix(destination.final.path + "/") else {
                throw ExportFileWriterError.archivePublishFailed
            }
            return published
        }

        _ = try validatedArchiveParent(destination.parent)
        guard nodeType(destination.final) == nil else {
            throw ExportFileWriterError.archiveDestinationExists
        }
        try beforeArchiveRename?()
        let result = renamex_np(staging.path, destination.final.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            if errno == EEXIST { throw ExportFileWriterError.archiveDestinationExists }
            throw ExportFileWriterError.archivePublishFailed
        }
        published = true
        return ExportDirectoryWriteResult(
            documentFileCount: staged.documentFileCount,
            files: publishedFiles,
            warnings: staged.warnings
        )
    }

    public func writeMarkdown(
        _ bundle: ExportBundle,
        layout: ExportFileLayout,
        profile: MarkdownProfile = .plain,
        coverMode: ExportCoverMode = .none,
        overwrite: OverwritePolicy = .never
    ) throws -> ExportDirectoryWriteResult {
        let producesMultipleFiles = layout == .perBook || coverMode == .file || profile.options.authorPages
        if producesMultipleFiles,
           ExportSafetyValidator.requiresCompleteNoteArchiveValidation(bundle.options),
           permitsCompleteArchivePerBookWrites == false {
            throw ExportFileWriterError.completeArchiveRequiresStaging
        }
        var files: [URL] = []
        var warnings: [ExportFileWriteWarning] = []
        let authorTargets = authorTargets(for: bundle.groups, profile: profile)

        switch layout {
        case let .single(fileName):
            var attachmentAllocator = ExportFilenameAllocator()
            let contexts = try markdownContexts(
                groups: bundle.groups,
                coverMode: coverMode,
                overwrite: overwrite,
                attachmentAllocator: &attachmentAllocator,
                authorTargets: authorTargets,
                files: &files
            )
            let stable = Data(
                MarkdownAnnotationExporter.render(bundle, profile: profile, contexts: contexts).utf8
            )
            let result = try writeGenerated(
                stableData: stable,
                fileName: fileName,
                parent: outputRoot,
                overwrite: overwrite
            ) { hash, exportedAt in
                Data(
                    MarkdownAnnotationExporter.render(
                        bundle,
                        profile: profile,
                        contexts: contexts,
                        fileMetadata: profile.options.extendedFrontmatter
                            ? MarkdownFileMetadata(stableHash: hash, exportedAt: exportedAt)
                            : nil
                    ).utf8
                )
            }
            files.append(result.destination)
            warnings += writeAuthorPages(
                groups: bundle.groups,
                documentFiles: Array(repeating: result.destination, count: bundle.groups.count),
                profile: profile,
                targets: authorTargets,
                overwrite: overwrite,
                files: &files
            )
            return ExportDirectoryWriteResult(
                documentFileCount: 1,
                files: files,
                warnings: warnings
            )

        case .perBook:
            var documentAllocator = ExportFilenameAllocator()
            var attachmentAllocator = ExportFilenameAllocator()
            let contexts = try markdownContexts(
                groups: bundle.groups,
                coverMode: coverMode,
                overwrite: overwrite,
                attachmentAllocator: &attachmentAllocator,
                authorTargets: authorTargets,
                files: &files
            )
            var documentFiles: [URL] = []
            for (index, group) in bundle.groups.enumerated() {
                let fileName = documentAllocator.allocate(
                    derivedFrom: Self.fileStem(for: group),
                    extension: "md"
                )
                let context = contexts[index] ?? MarkdownRenderContext()
                let stable = Data(
                    MarkdownAnnotationExporter.render(group, profile: profile, context: context).utf8
                )
                let result = try writeGenerated(
                    stableData: stable,
                    fileName: fileName,
                    parent: outputRoot,
                    overwrite: overwrite
                ) { hash, exportedAt in
                    Data(
                        MarkdownAnnotationExporter.render(
                            group,
                            profile: profile,
                            context: context,
                            fileMetadata: profile.options.extendedFrontmatter
                                ? MarkdownFileMetadata(stableHash: hash, exportedAt: exportedAt)
                                : nil
                        ).utf8
                    )
                }
                documentFiles.append(result.destination)
                files.append(result.destination)
            }
            warnings += writeAuthorPages(
                groups: bundle.groups,
                documentFiles: documentFiles,
                profile: profile,
                targets: authorTargets,
                overwrite: overwrite,
                files: &files
            )
            return ExportDirectoryWriteResult(
                documentFileCount: documentFiles.count,
                files: files,
                warnings: warnings
            )
        }
    }

    private func markdownContexts(
        groups: [ExportGroup],
        coverMode: ExportCoverMode,
        overwrite: OverwritePolicy,
        attachmentAllocator: inout ExportFilenameAllocator,
        authorTargets: [String: String],
        files: inout [URL]
    ) throws -> [Int: MarkdownRenderContext] {
        var contexts: [Int: MarkdownRenderContext] = [:]
        let attachments = coverMode == .file ? try controlledDirectory(named: "Attachments") : nil

        for (index, group) in groups.enumerated() {
            var context = MarkdownRenderContext()
            if let author = Self.author(for: group), let target = authorTargets[author] {
                context.authorLinkTarget = target
            }
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

    private func authorTargets(
        for groups: [ExportGroup],
        profile: MarkdownProfile
    ) -> [String: String] {
        guard profile.options.authorLinks || profile.options.authorPages else { return [:] }
        var allocator = ExportFilenameAllocator()
        var result: [String: String] = [:]
        for group in groups {
            guard let author = Self.author(for: group), result[author] == nil else { continue }
            let fileName = allocator.allocate(derivedFrom: author, extension: "md")
            result[author] = "Authors/\(String(fileName.dropLast(3)))"
        }
        return result
    }

    private func writeAuthorPages(
        groups: [ExportGroup],
        documentFiles: [URL],
        profile: MarkdownProfile,
        targets: [String: String],
        overwrite: OverwritePolicy,
        files: inout [URL]
    ) -> [ExportFileWriteWarning] {
        guard profile.options.authorPages else { return [] }
        guard let authorsDirectory = try? controlledDirectory(named: "Authors") else {
            return [.authorPageFailed]
        }

        var grouped: [String: [(title: String, file: URL)]] = [:]
        for (index, group) in groups.enumerated() {
            guard documentFiles.indices.contains(index), let author = Self.author(for: group) else { continue }
            grouped[author, default: []].append((Self.fileStem(for: group), documentFiles[index]))
        }

        var warnings: [ExportFileWriteWarning] = []
        for author in grouped.keys.sorted() {
            guard let target = targets[author], let entries = grouped[author] else { continue }
            let fileName = String(target.dropFirst("Authors/".count)) + ".md"
            let body = Self.authorPage(author: author, entries: entries, profile: profile)
            do {
                let result = try writeGenerated(
                    stableData: Data(body.utf8),
                    fileName: fileName,
                    parent: authorsDirectory,
                    overwrite: overwrite
                ) { _, _ in Data(body.utf8) }
                files.append(result.destination)
            } catch {
                warnings.append(.authorPageFailed)
            }
        }
        return warnings
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

    private static func validatedArchiveDestination(_ raw: URL) throws -> (final: URL, parent: URL) {
        guard raw.isFileURL, raw.path.hasPrefix("/") else {
            throw ExportFileWriterError.invalidOutputRoot
        }
        let standardized = raw.standardizedFileURL
        try validateFileName(standardized.lastPathComponent)
        guard nodeType(standardized) == nil else {
            throw ExportFileWriterError.archiveDestinationExists
        }
        let parent = try validatedArchiveParent(standardized.deletingLastPathComponent().standardizedFileURL)
        let final = parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true).standardizedFileURL
        guard final.deletingLastPathComponent().path == parent.path else {
            throw ExportFileWriterError.unsafeOutputRoot
        }
        return (final, parent)
    }

    private static func validatedArchiveParent(_ raw: URL) throws -> URL {
        let standardized = raw.standardizedFileURL
        guard nodeType(standardized) == S_IFDIR else { throw ExportFileWriterError.unsafeOutputRoot }
        let canonical = standardized.resolvingSymlinksInPath()
        guard canonical.path == standardized.path else { throw ExportFileWriterError.unsafeOutputRoot }
        return canonical
    }

    private static func createArchiveStaging(parent: URL) throws -> URL {
        _ = try validatedArchiveParent(parent)
        let staging = parent.appendingPathComponent(
            ".applebookscli-archive-\(UUID().uuidString).staging",
            isDirectory: true
        ).standardizedFileURL
        guard staging.deletingLastPathComponent().path == parent.path, nodeType(staging) == nil else {
            throw ExportFileWriterError.archivePublishFailed
        }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw ExportFileWriterError.archivePublishFailed
        }
        guard nodeType(staging) == S_IFDIR,
              staging.resolvingSymlinksInPath().path == staging.path else {
            throw ExportFileWriterError.archivePublishFailed
        }
        return staging
    }

    private static func removeControlledArchiveStaging(_ staging: URL, parent: URL) {
        let name = staging.lastPathComponent
        guard name.hasPrefix(".applebookscli-archive-"),
              name.hasSuffix(".staging"),
              staging.deletingLastPathComponent().standardizedFileURL.path == parent.path,
              nodeType(parent) == S_IFDIR,
              parent.resolvingSymlinksInPath().path == parent.path,
              nodeType(staging) == S_IFDIR,
              staging.resolvingSymlinksInPath().path == staging.path else {
            return
        }
        try? FileManager.default.removeItem(at: staging)
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
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard text.hasPrefix("---\n") else { return data }
        let lines = text.components(separatedBy: "\n")
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return data }
        var normalized: [String] = []
        for (index, line) in lines.enumerated() {
            let isFrontmatterValue = index > 0 && index < closingIndex
            let isRunMetadata = line.hasPrefix("last-import-hash:") ||
                line.hasPrefix("last_import_hash:") ||
                line.hasPrefix("exported_at:") ||
                line.hasPrefix("exported:")
            if isFrontmatterValue && isRunMetadata { continue }
            normalized.append(line)
        }
        return Data(normalized.joined(separator: "\n").utf8)
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

    private static func author(for group: ExportGroup) -> String? {
        switch group.source {
        case let .epubCurrent(book):
            nonEmpty(book.author) ?? nonEmpty(group.epubMetadata?.creator)
        case let .epubHistorical(_, metadata):
            nonEmpty(metadata.author)
        case .epubUnmapped:
            nil
        case let .pdf(source):
            source.book.flatMap { nonEmpty($0.author) }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else { return nil }
        return value
    }

    private static func authorPage(
        author: String,
        entries: [(title: String, file: URL)],
        profile: MarkdownProfile
    ) -> String {
        let heading = markdownEscape(author.replacingOccurrences(of: "\n", with: " "))
        if profile.syntax == .obsidian {
            let encodedAuthor = MarkdownYAML.quotedScalar(author)
            return """
            # \(heading)

            ```dataview
            LIST
            WHERE author = \(encodedAuthor)
            ```
            """ + "\n"
        }
        let links = entries.map { entry in
            let target = "../\(entry.file.lastPathComponent)"
            return "- [\(markdownEscape(entry.title))](<\(target)>)"
        }.joined(separator: "\n")
        return "# \(heading)\n\n\(links)\n"
    }

    private static func markdownEscape(_ value: String) -> String {
        let structural = Set("\\`*_{}[]<>()#+!|")
        var output = ""
        for character in value {
            if structural.contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }
}
