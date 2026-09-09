import CryptoKit
import Darwin
import Foundation

struct PDFSourceResolver {
    let fallbackRoot: URL
    private let sourceIDDigest: (Data) -> [UInt8]

    init(
        fallbackRoot: URL = Self.defaultFallbackRoot,
        sourceIDDigest: @escaping (Data) -> [UInt8] = PDFSourceID.defaultDigest
    ) {
        self.fallbackRoot = fallbackRoot
        self.sourceIDDigest = sourceIDDigest
    }

    // Full materialization remains for explicit archival/export compatibility.
    func resolve(pdfBooks: [Book]) -> [PDFSource] {
        let booksByPath = booksByValidatedPath(pdfBooks)
        let fallbackPaths = fallbackPDFs()
        var allPaths = Set(booksByPath.keys)
        allPaths.formUnion(fallbackPaths)

        return allPaths
            .sorted { binaryLess($0.path, $1.path) }
            .map {
                source(
                    fileURL: $0,
                    booksByPath: booksByPath,
                    provenance: booksByPath[$0] == nil ? .fallback : .library
                )
            }
    }

    // Full materialization remains for explicit archival/export compatibility.
    func resolve(pdfResources: [BookPDFResource]) -> [PDFSource] {
        let summariesByPath = summariesByValidatedPath(pdfResources)
        let fallbackPaths = fallbackPDFs()
        var allPaths = Set(summariesByPath.keys)
        allPaths.formUnion(fallbackPaths)
        return allPaths.sorted { binaryLess($0.path, $1.path) }.map { fileURL in
            semanticSource(
                fileURL: fileURL,
                summariesByPath: summariesByPath,
                provenance: summariesByPath[fileURL] == nil ? .fallback : .library
            )
        }
    }

    func inventoryPage(
        bookQueries: BookQueries,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<PDFInventorySummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let beforeLibrary = try scanLibrary(bookQueries: bookQueries)
        let beforeFallbackGeneration = try scanFallback { _ in }
        let beforeGeneration = try inventoryGeneration(
            bookQueries: bookQueries,
            libraryFiles: beforeLibrary.generation,
            fallback: beforeFallbackGeneration
        )
        let fingerprint = try CursorQueryFingerprint.make(
            kind: "pdf.list",
            fields: [CursorFingerprintField("order.version", .unsigned(1))]
        )
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )

        let afterLibrary = try scanLibrary(bookQueries: bookQueries)
        let anchor = try inventoryAnchor(from: session.locator, library: afterLibrary)
        var anchorFound = anchor == nil || anchor?.kind == .book
        var candidates: [InventoryCandidate] = []
        candidates.reserveCapacity(effectiveLimit + 1)

        for group in afterLibrary.groups.values {
            let candidate = try libraryCandidate(group)
            if candidate.key == anchor { anchorFound = true }
            try retain(
                candidate,
                after: anchor,
                maximumCount: effectiveLimit + 1,
                in: &candidates
            )
        }

        let libraryFileIDs = Set(afterLibrary.groups.keys)
        let afterFallbackGeneration = try scanFallback { entry in
            guard libraryFileIDs.contains(entry.fileIdentity) == false else { return }
            let candidate = try fallbackCandidate(entry)
            if candidate.key == anchor { anchorFound = true }
            try retain(
                candidate,
                after: anchor,
                maximumCount: effectiveLimit + 1,
                in: &candidates
            )
        }
        guard anchorFound else { throw CursorPaginationError.staleCursor }

        let afterGeneration = try inventoryGeneration(
            bookQueries: bookQueries,
            libraryFiles: afterLibrary.generation,
            fallback: afterFallbackGeneration
        )
        let hasMore = candidates.count > effectiveLimit
        let pageCandidates = Array(candidates.prefix(effectiveLimit))
        let localPKs = pageCandidates.compactMap(\.summaryLocalPK)
        let summaries = try bookQueries.semanticSummaries(localPKs: localPKs)
        let items = pageCandidates.map { candidate in
            let summary = candidate.summaryLocalPK.flatMap { summaries[$0] }
            let title = summary?.title ?? candidate.fallbackTitle
            return PDFInventorySummary(
                bookAssetID: candidate.key.kind == .book ? candidate.key.value : nil,
                pdfSourceID: candidate.key.kind == .source ? candidate.key.value : nil,
                title: title,
                provenance: candidate.provenance,
                byteTruncatedFields: summary?.byteTruncatedFields.filter { $0 == "title" } ?? []
            )
        }
        let nextLocator = hasMore ? try pageCandidates.last.map(locator(for:)) : nil
        let nextCursor = try session.nextCursor(
            after: afterGeneration,
            hasMore: hasMore,
            locator: nextLocator
        )
        return CursorPage(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }

    func resolve(sourceID: PDFSourceID, bookQueries: BookQueries) throws -> PDFSource? {
        let library = try scanLibrary(bookQueries: bookQueries)
        var match: PDFSource?
        var matchCount = 0

        for group in library.groups.values {
            let candidate = try libraryCandidate(group)
            guard candidate.key.kind == .source, candidate.key.value == sourceID.rawValue else { continue }
            matchCount += 1
            guard matchCount == 1 else { throw PDFInventoryError.ambiguousSourceID }
            let summary: BookSummary? = if let localPK = candidate.summaryLocalPK {
                try bookQueries.semanticSummary(localPK: localPK)
            } else {
                nil
            }
            match = PDFSource(
                fileURL: candidate.fileURL,
                bookSummary: summary,
                provenance: .library,
                pdfSourceID: sourceID.rawValue
            )
        }

        let libraryFileIDs = Set(library.groups.keys)
        _ = try scanFallback { entry in
            guard libraryFileIDs.contains(entry.fileIdentity) == false else { return }
            let candidate = try fallbackCandidate(entry)
            guard candidate.key.value == sourceID.rawValue else { return }
            matchCount += 1
            guard matchCount == 1 else { throw PDFInventoryError.ambiguousSourceID }
            match = PDFSource(
                fileURL: entry.fileURL,
                bookSummary: nil,
                provenance: .fallback,
                pdfSourceID: sourceID.rawValue
            )
        }
        return match
    }

    func resolve(resource: BookPDFResource) -> PDFSource? {
        resolve(target: resource.target, summary: resource.summary)
    }

    func resolve(target: BookResourceTarget, summary: BookSummary?) -> PDFSource? {
        guard target.contentType == 3,
              let rawPath = target.path,
              let validated = validatedLibraryPDF(rawPath: rawPath) else {
            return nil
        }
        return PDFSource(fileURL: validated.fileURL, bookSummary: summary, provenance: .library)
    }

    func resolve(fileURL: URL, pdfResources: [BookPDFResource]) -> PDFSource? {
        guard let validated = validatedPDFURL(fileURL: fileURL) else { return nil }
        let summariesByPath = summariesByValidatedPath(pdfResources)
        return semanticSource(
            fileURL: validated,
            summariesByPath: summariesByPath,
            provenance: summariesByPath[validated] == nil ? .explicit : .library
        )
    }

    func resolve(book: Book) -> PDFSource? {
        guard book.contentType == 3,
              let rawPath = book.path,
              let validated = validatedLibraryPDF(rawPath: rawPath) else {
            return nil
        }
        return PDFSource(fileURL: validated.fileURL, book: book, provenance: .library)
    }

    func resolve(fileURL: URL, pdfBooks: [Book]) -> PDFSource? {
        guard let validated = validatedPDFURL(fileURL: fileURL) else { return nil }
        let booksByPath = booksByValidatedPath(pdfBooks)
        return source(
            fileURL: validated,
            booksByPath: booksByPath,
            provenance: booksByPath[validated] == nil ? .explicit : .library
        )
    }

    private func scanLibrary(bookQueries: BookQueries) throws -> LibraryScan {
        var groups: [FileIdentity: LibraryGroup] = [:]
        var hasher = SHA256()
        hasher.update(data: Data("applebookscli.pdf.library-files.v1".utf8))

        try bookQueries.forEachPDFResourceTarget { target, assetMultiplicity in
            var generationRow = Data()
            appendUInt64(UInt64(bitPattern: target.localPK), to: &generationRow)
            guard let rawPath = target.path,
                  let validated = validatedLibraryPDF(rawPath: rawPath) else {
                generationRow.append(0)
                hasher.update(data: generationRow)
                return true
            }
            generationRow.append(1)
            validated.metadata.appendForPDFGeneration(to: &generationRow)
            hasher.update(data: generationRow)

            if var group = groups[validated.fileIdentity] {
                group.rowCount += 1
                if binaryLess(validated.fileURL.path, group.slotPath) {
                    group.slotPath = validated.fileURL.path
                }
                groups[validated.fileIdentity] = group
            } else {
                groups[validated.fileIdentity] = LibraryGroup(
                    fileIdentity: validated.fileIdentity,
                    rowCount: 1,
                    soleLocalPK: target.localPK,
                    soleAssetID: target.assetID,
                    soleAssetMultiplicity: assetMultiplicity,
                    slotPath: validated.fileURL.path
                )
            }
            return true
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return LibraryScan(
            groups: groups,
            generation: try .synthetic(label: "pdf-library-files", value: digest)
        )
    }

    private func inventoryGeneration(
        bookQueries: BookQueries,
        libraryFiles: CursorGenerationComponent,
        fallback: CursorGenerationComponent
    ) throws -> CursorGeneration {
        try CursorGeneration.compose([
            .sqlite(label: "library", databaseURL: bookQueries.connection.databaseURL),
            libraryFiles,
            fallback,
        ])
    }

    private func inventoryAnchor(
        from locator: CursorLocator?,
        library: LibraryScan
    ) throws -> InventoryKey? {
        guard let locator else { return nil }
        switch locator.words {
        case let words where words.count == 2 && words[0] == 0:
            let localPK = Int64(bitPattern: words[1])
            guard localPK > 0 else { throw CursorPaginationError.invalidCursor }
            let matches = try library.groups.values.compactMap { group -> InventoryKey? in
                let candidate = try libraryCandidate(group)
                guard candidate.summaryLocalPK == localPK, candidate.key.kind == .book else { return nil }
                return candidate.key
            }
            guard matches.count == 1 else { throw CursorPaginationError.staleCursor }
            return matches[0]
        case let words where words.count == 5 && words[0] == 1:
            var digest: [UInt8] = []
            digest.reserveCapacity(PDFSourceID.digestByteCount)
            for word in words.dropFirst() {
                for shift in stride(from: 56, through: 0, by: -8) {
                    digest.append(UInt8((word >> UInt64(shift)) & 0xff))
                }
            }
            let raw = PDFSourceID.prefix + digest.map { String(format: "%02x", $0) }.joined()
            return .source(try PDFSourceID.parse(raw))
        default:
            throw CursorPaginationError.invalidCursor
        }
    }

    private func locator(for candidate: InventoryCandidate) throws -> CursorLocator {
        switch candidate.key.kind {
        case .book:
            guard let localPK = candidate.summaryLocalPK else {
                throw CursorPaginationError.internalContractFailure
            }
            return try CursorLocator(words: [0, UInt64(bitPattern: localPK)])
        case .source:
            let sourceID = try PDFSourceID.parse(candidate.key.value)
            let bytes = sourceID.digestBytes
            var words: [UInt64] = [1]
            words.reserveCapacity(5)
            for start in stride(from: 0, to: bytes.count, by: 8) {
                var word: UInt64 = 0
                for byte in bytes[start..<(start + 8)] {
                    word = (word << 8) | UInt64(byte)
                }
                words.append(word)
            }
            return try CursorLocator(words: words)
        }
    }

    private func libraryCandidate(_ group: LibraryGroup) throws -> InventoryCandidate {
        let fileURL = URL(fileURLWithPath: group.slotPath).standardizedFileURL
        if group.rowCount == 1,
           group.soleAssetMultiplicity == 1,
           let assetID = group.soleAssetID,
           PublicStableIdentityPolicy.isEligible(assetID) {
            return InventoryCandidate(
                key: .book(assetID: assetID),
                fileURL: fileURL,
                provenance: .library,
                summaryLocalPK: group.soleLocalPK,
                fallbackTitle: fileURL.deletingPathExtension().lastPathComponent
            )
        }
        let sourceID = try librarySourceID(slotPath: group.slotPath)
        return InventoryCandidate(
            key: .source(sourceID),
            fileURL: fileURL,
            provenance: .library,
            summaryLocalPK: group.rowCount == 1 ? group.soleLocalPK : nil,
            fallbackTitle: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    private func fallbackCandidate(_ entry: FallbackEntry) throws -> InventoryCandidate {
        let sourceID = try fallbackSourceID(root: entry.rootIdentity, entryName: entry.name)
        return InventoryCandidate(
            key: .source(sourceID),
            fileURL: entry.fileURL,
            provenance: .fallback,
            summaryLocalPK: nil,
            fallbackTitle: entry.fileURL.deletingPathExtension().lastPathComponent
        )
    }

    private func retain(
        _ candidate: InventoryCandidate,
        after anchor: InventoryKey?,
        maximumCount: Int,
        in retained: inout [InventoryCandidate]
    ) throws {
        if let anchor, candidate.key <= anchor { return }
        if let duplicate = retained.first(where: { $0.key == candidate.key }) {
            guard duplicate.fileURL == candidate.fileURL else {
                throw PDFInventoryError.ambiguousSourceID
            }
            return
        }
        let insertion = retained.firstIndex(where: { candidate.key < $0.key }) ?? retained.endIndex
        guard insertion < maximumCount else { return }
        retained.insert(candidate, at: insertion)
        if retained.count > maximumCount { retained.removeLast() }
    }

    private func librarySourceID(slotPath: String) throws -> PDFSourceID {
        var payload = Data("applebookscli.pdf-source.library.v1".utf8)
        appendLengthPrefixed(Data(slotPath.utf8), to: &payload)
        return try PDFSourceID.make(payload: payload, digest: sourceIDDigest)
    }

    private func fallbackSourceID(root: FileIdentity, entryName: String) throws -> PDFSourceID {
        var payload = Data("applebookscli.pdf-source.fallback.v1".utf8)
        appendUInt64(root.device, to: &payload)
        appendUInt64(root.inode, to: &payload)
        appendLengthPrefixed(Data(entryName.utf8), to: &payload)
        return try PDFSourceID.make(payload: payload, digest: sourceIDDigest)
    }

    @discardableResult
    private func scanFallback(
        _ body: (FallbackEntry) throws -> Void
    ) throws -> CursorGenerationComponent {
        let root = fallbackRoot.standardizedFileURL
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else {
            return try .synthetic(
                label: "pdf-fallback",
                value: errno == ENOENT ? "missing" : "unavailable"
            )
        }

        guard let directory = fdopendir(rootFD) else {
            close(rootFD)
            return try .synthetic(label: "pdf-fallback", value: "unavailable")
        }
        defer { closedir(directory) }
        let directoryFD = dirfd(directory)
        var rootStat = stat()
        guard fstat(directoryFD, &rootStat) == 0,
              rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw CursorPaginationError.generationUnavailable
        }
        let rootMetadata = metadata(from: rootStat)
        let rootIdentity = FileIdentity(device: rootMetadata.device, inode: rootMetadata.inode)
        var generation = try CursorDirectoryGenerationBuilder(
            label: "pdf-fallback",
            rootURL: root,
            validatedRootMetadata: rootMetadata
        )

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw CursorPaginationError.generationUnavailable }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                }
            }
            guard isEligibleFallbackName(name) else { continue }

            let fileFD = name.withCString {
                openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard fileFD >= 0 else { continue }
            var fileStat = stat()
            let statResult = fstat(fileFD, &fileStat)
            close(fileFD)
            guard statResult == 0,
                  fileStat.st_mode & S_IFMT == S_IFREG,
                  fileStat.st_size >= 0 else {
                continue
            }
            let fileMetadata = metadata(from: fileStat)
            try generation.add(relativeName: name, metadata: fileMetadata)
            try body(FallbackEntry(
                rootIdentity: rootIdentity,
                name: name,
                fileURL: root.appendingPathComponent(name, isDirectory: false).standardizedFileURL,
                fileIdentity: FileIdentity(device: fileMetadata.device, inode: fileMetadata.inode)
            ))
        }
        return try generation.finish()
    }

    private func isEligibleFallbackName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard name != ".", name != "..",
              bytes.isEmpty == false,
              bytes.count <= 4_096,
              bytes.contains(0) == false,
              name.contains("/") == false else {
            return false
        }
        return (name as NSString).pathExtension.lowercased() == "pdf"
    }

    private func validatedLibraryPDF(rawPath: String) -> ValidatedFile? {
        guard rawPath.hasPrefix("/"),
              rawPath.utf8.count <= SQLiteSemanticTextBudget.resourcePath,
              rawPath.utf8.contains(0) == false else {
            return nil
        }
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard standardized.path == rawPath,
              standardized.pathExtension.lowercased() == "pdf" else {
            return nil
        }
        return openRegularPDF(standardized)
    }

    private func validatedPDFURL(fileURL: URL) -> URL? {
        let standardized = fileURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "pdf",
              let validated = openRegularPDF(standardized) else {
            return nil
        }
        return validated.fileURL
    }

    private func openRegularPDF(_ fileURL: URL) -> ValidatedFile? {
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0 else {
            return nil
        }
        let fileMetadata = metadata(from: info)
        return ValidatedFile(
            fileURL: fileURL,
            metadata: fileMetadata,
            fileIdentity: FileIdentity(device: fileMetadata.device, inode: fileMetadata.inode)
        )
    }

    private func metadata(from info: stat) -> CursorFileMetadata {
        CursorFileMetadata(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func fallbackPDFs() -> Set<URL> {
        var result = Set<URL>()
        _ = try? scanFallback { result.insert($0.fileURL) }
        return result
    }

    private func summariesByValidatedPath(_ resources: [BookPDFResource]) -> [URL: [BookSummary]] {
        var summariesByPath: [URL: [BookSummary]] = [:]
        for resource in resources {
            guard let rawPath = resource.target.path,
                  let validated = validatedLibraryPDF(rawPath: rawPath) else {
                continue
            }
            summariesByPath[validated.fileURL, default: []].append(resource.summary)
        }
        return summariesByPath
    }

    private func semanticSource(
        fileURL: URL,
        summariesByPath: [URL: [BookSummary]],
        provenance: PDFSourceProvenance
    ) -> PDFSource {
        let matches = summariesByPath[fileURL] ?? []
        return PDFSource(
            fileURL: fileURL,
            bookSummary: matches.count == 1 ? matches[0] : nil,
            provenance: provenance
        )
    }

    private func booksByValidatedPath(_ pdfBooks: [Book]) -> [URL: [Book]] {
        var booksByPath: [URL: [Book]] = [:]
        for book in pdfBooks {
            guard let rawPath = book.path,
                  let validated = validatedLibraryPDF(rawPath: rawPath) else {
                continue
            }
            booksByPath[validated.fileURL, default: []].append(book)
        }
        return booksByPath
    }

    private func source(
        fileURL: URL,
        booksByPath: [URL: [Book]],
        provenance: PDFSourceProvenance
    ) -> PDFSource {
        let matches = booksByPath[fileURL] ?? []
        return PDFSource(
            fileURL: fileURL,
            book: matches.count == 1 ? matches[0] : nil,
            provenance: provenance
        )
    }

    private static var defaultFallbackRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("iCloud~com~apple~iBooks", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }
}

private enum PDFInventoryIdentityKind: UInt64 {
    case book = 0
    case source = 1
}

private enum InventoryKey: Equatable, Comparable {
    case book(assetID: String)
    case source(PDFSourceID)

    var kind: PDFInventoryIdentityKind {
        switch self {
        case .book: .book
        case .source: .source
        }
    }

    var value: String {
        switch self {
        case let .book(assetID): assetID
        case let .source(sourceID): sourceID.rawValue
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return binaryLess(lhs.value, rhs.value)
    }
}

private struct InventoryCandidate {
    let key: InventoryKey
    let fileURL: URL
    let provenance: PDFSourceProvenance
    let summaryLocalPK: Int64?
    let fallbackTitle: String
}

private struct LibraryScan {
    let groups: [FileIdentity: LibraryGroup]
    let generation: CursorGenerationComponent
}

private struct LibraryGroup {
    let fileIdentity: FileIdentity
    var rowCount: Int
    let soleLocalPK: Int64
    let soleAssetID: String?
    let soleAssetMultiplicity: Int
    var slotPath: String
}

private struct FallbackEntry {
    let rootIdentity: FileIdentity
    let name: String
    let fileURL: URL
    let fileIdentity: FileIdentity
}

private struct ValidatedFile {
    let fileURL: URL
    let metadata: CursorFileMetadata
    let fileIdentity: FileIdentity
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private extension CursorFileMetadata {
    func appendForPDFGeneration(to data: inout Data) {
        appendUInt64(device, to: &data)
        appendUInt64(inode, to: &data)
        appendUInt64(size, to: &data)
        appendUInt64(UInt64(bitPattern: modificationSeconds), to: &data)
        appendUInt64(UInt64(bitPattern: modificationNanoseconds), to: &data)
    }
}

private func appendLengthPrefixed(_ value: Data, to data: inout Data) {
    appendUInt64(UInt64(value.count), to: &data)
    data.append(value)
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
}

private func binaryLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
