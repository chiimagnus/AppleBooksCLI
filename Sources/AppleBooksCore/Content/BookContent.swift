import Darwin
import Foundation

public enum BookContentError: Error, Equatable, Sendable {
    case chapterNotFound
    case invalidMaximumCharacters
    case chapterOffsetOutOfRange(offset: Int, total: Int)
}

package struct SemanticChapterContinuationPage: Equatable, Sendable {
    package let bookLocalPK: Int64
    package let bookAssetID: String?
    package let chapterOrder: Int
    package let content: String
    package let hasMore: Bool
    package let nextCursor: String?
}

package enum ChapterContinuationPolicy {
    package static let defaultMaximumCharacters = 4_000
    package static let maximumCharacters = 16_000
    package static let defaultMaximumUTF8Bytes = 32 * 1_024
    package static let maximumUTF8Bytes = 128 * 1_024

    package static func limits(maximumCharacters requested: Int?) throws -> (characters: Int, utf8Bytes: Int) {
        guard let requested else {
            return (defaultMaximumCharacters, defaultMaximumUTF8Bytes)
        }
        guard (1...maximumCharacters).contains(requested) else {
            throw BookContentError.invalidMaximumCharacters
        }
        return (requested, maximumUTF8Bytes)
    }
}

public final class BookContent {
    let package: DirectoryEPUBPackage
    private let navigation: EPUBNavigation

    public convenience init(root: URL) throws {
        guard root.standardizedFileURL.pathExtension.lowercased() == "epub" else {
            throw ContentError.unsupportedFormat
        }
        try self.init(reader: DirectoryEPUBResourceReader(root: root))
    }

    init(reader: any EPUBResourceReader) throws {
        let package = try DirectoryEPUBPackage(reader: reader)
        switch try EPUBEncryption.inspect(package: package) {
        case .none, .fontObfuscationOnly:
            break
        case .contentEncryptionUnsupported:
            throw ContentError.contentEncryptionUnsupported
        case .malformedEncryptionMetadata:
            throw ContentError.malformedEncryptionMetadata
        }
        self.package = package
        navigation = EPUBNavigation(package: package)
    }

    public func listChapters() throws -> [Chapter] {
        let discovered = try navigation.chaptersFromNavigation()
        if discovered.isEmpty == false { return discovered }
        let idCounts = Dictionary(grouping: package.spine, by: \.idref).mapValues(\.count)
        return package.spine.map { spine in
            let item = package.manifest[spine.idref]!
            let id = spine.idref.isEmpty || idCounts[spine.idref, default: 0] > 1
                ? String(spine.order)
                : spine.idref
            return Chapter(
                id: id,
                title: "Section \(spine.order)",
                href: item.path.relativePath,
                fragment: "",
                order: spine.order,
                depth: 0
            )
        }
    }

    func annotationReadingContext() throws -> (chapterOrder: [String: Int], generation: CursorGenerationComponent) {
        var chapterOrder: [String: Int] = [:]
        for chapter in try listChapters() {
            chapterOrder[chapter.id] = min(chapterOrder[chapter.id] ?? .max, chapter.order)
        }

        let generation: CursorGenerationComponent
        if let directory = package.reader as? DirectoryEPUBResourceReader {
            var paths = [
                try EPUBPath.resolve(reference: "META-INF/container.xml"),
                package.packageDocument,
            ]
            for item in package.manifest.values where
                item.properties.contains("nav") || item.mediaType == "application/x-dtbncx+xml" {
                if try directory.contains(item.path) { paths.append(item.path) }
            }
            let encryption = try EPUBPath.resolve(reference: "META-INF/encryption.xml")
            if try directory.contains(encryption) { paths.append(encryption) }
            generation = try directory.cursorGenerationComponent(label: "reading-context", paths: paths)
        } else if let archive = package.reader as? ZIPEPUBResourceReader {
            generation = try .regularFile(label: "reading-context", url: archive.fileURL)
        } else {
            generation = try .synthetic(label: "reading-context", value: "parsed")
        }
        return (chapterOrder, generation)
    }

    public func getChapter(_ selector: String) throws -> String {
        let chapter = try resolveChapter(selector)
        let data = try readChapterBytes(chapter)
        return try XHTMLText.extract(
            data,
            fragment: chapter.fragment.isEmpty ? nil : chapter.fragment,
            stopFragments: try stopFragments(for: chapter)
        )
    }

    public func chapterPage(
        id: String,
        offset: Int = 0,
        maxCharacters: Int? = 10_000
    ) throws -> ChapterPage {
        let text = try getChapter(id)
        if let maxCharacters, maxCharacters <= 0 {
            throw BookContentError.invalidMaximumCharacters
        }

        let total = text.count
        guard total > 0 else {
            return ChapterPage(
                content: "",
                offset: 0,
                endOffset: 0,
                totalCharacters: 0,
                hasMore: false,
                nextOffset: nil
            )
        }

        let effectiveOffset = max(offset, 0)
        guard effectiveOffset < total else {
            throw BookContentError.chapterOffsetOutOfRange(offset: effectiveOffset, total: total)
        }
        let remaining = total - effectiveOffset
        let returnedCharacters = maxCharacters.map { min($0, remaining) } ?? remaining
        let endOffset = effectiveOffset + returnedCharacters
        let startIndex = text.index(text.startIndex, offsetBy: effectiveOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)
        let hasMore = endOffset < total
        return ChapterPage(
            content: String(text[startIndex..<endIndex]),
            offset: effectiveOffset,
            endOffset: endOffset,
            totalCharacters: total,
            hasMore: hasMore,
            nextOffset: hasMore ? endOffset : nil
        )
    }

    func resolveChapter(order: Int) throws -> Chapter {
        guard order > 0, let chapter = try listChapters().first(where: { $0.order == order }) else {
            throw BookContentError.chapterNotFound
        }
        return chapter
    }

    func continuationPage(
        chapter: Chapter,
        offset: Int,
        maximumGraphemes: Int,
        maximumUTF8Bytes: Int
    ) throws -> XHTMLTextPage {
        let data = try readChapterBytes(chapter)
        let page = try XHTMLText.page(
            data,
            fragment: chapter.fragment.isEmpty ? nil : chapter.fragment,
            stopFragments: try stopFragments(for: chapter),
            offset: offset,
            maximumGraphemes: maximumGraphemes,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        if offset > 0, page.returnedGraphemes == 0, page.hasMore == false {
            throw CursorPaginationError.staleCursor
        }
        return page
    }

    func chapterCursorGenerationComponent(for chapter: Chapter) throws -> CursorGenerationComponent {
        if let directory = package.reader as? DirectoryEPUBResourceReader {
            var paths = [
                try EPUBPath.resolve(reference: "META-INF/container.xml"),
                package.packageDocument,
                try chapterResourcePath(chapter),
            ]
            for item in package.manifest.values where
                item.properties.contains("nav") || item.mediaType == "application/x-dtbncx+xml" {
                if try directory.contains(item.path) { paths.append(item.path) }
            }
            let encryption = try EPUBPath.resolve(reference: "META-INF/encryption.xml")
            if try directory.contains(encryption) { paths.append(encryption) }
            return try directory.cursorGenerationComponent(label: "chapter-source", paths: paths)
        }
        if let archive = package.reader as? ZIPEPUBResourceReader {
            return try .regularFile(label: "chapter-source", url: archive.fileURL)
        }
        return try .synthetic(label: "chapter-source", value: "parsed")
    }

    func resolveChapter(_ selector: String) throws -> Chapter {
        let chapters = try listChapters()
        if let chapter = chapters.first(where: { $0.id == selector }) {
            return chapter
        }
        if let order = Int(selector), let chapter = chapters.first(where: { $0.order == order }) {
            return chapter
        }
        if let spine = package.spine.first(where: { $0.idref == selector }),
           let item = package.manifest[spine.idref] {
            return Chapter(
                id: spine.idref,
                title: "Section \(spine.order)",
                href: item.path.relativePath,
                fragment: "",
                order: spine.order,
                depth: 0
            )
        }
        throw BookContentError.chapterNotFound
    }

    func readChapterBytes(_ chapter: Chapter) throws -> Data {
        try package.reader.readExactResource(
            chapterResourcePath(chapter),
            maxBytes: EPUBResourceBudget.chapter
        )
    }

    private func chapterResourcePath(_ chapter: Chapter) throws -> EPUBPath {
        let matching = package.manifest.values.filter { $0.path.relativePath == chapter.href }
        if matching.count == 1, let manifestPath = matching.first?.path {
            return EPUBPath(
                relativePath: manifestPath.relativePath,
                fragment: chapter.fragment.isEmpty ? nil : chapter.fragment
            )
        }
        return try EPUBPath.resolve(reference: chapter.href)
    }

    private func stopFragments(for chapter: Chapter) throws -> Set<String> {
        guard chapter.fragment.isEmpty == false else { return [] }
        return Set(try listChapters().compactMap { candidate -> String? in
            guard candidate.href == chapter.href,
                  candidate.fragment.isEmpty == false,
                  candidate.fragment != chapter.fragment else { return nil }
            return candidate.fragment
        })
    }
}
