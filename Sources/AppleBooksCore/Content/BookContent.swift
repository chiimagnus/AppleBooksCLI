import Darwin
import Foundation

public enum BookContentError: Error, Equatable, Sendable {
    case chapterNotFound
    case invalidMaximumCharacters
    case chapterOffsetOutOfRange(offset: Int, total: Int)
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

    public func getChapter(_ selector: String) throws -> String {
        let chapter = try resolveChapter(selector)
        let data = try readChapterBytes(chapter)
        let stopFragments: Set<String>
        if chapter.fragment.isEmpty {
            stopFragments = []
        } else {
            stopFragments = Set(try listChapters().compactMap { candidate -> String? in
                guard candidate.href == chapter.href,
                      candidate.fragment.isEmpty == false,
                      candidate.fragment != chapter.fragment else { return nil }
                return candidate.fragment
            })
        }
        return try XHTMLText.extract(
            data,
            fragment: chapter.fragment.isEmpty ? nil : chapter.fragment,
            stopFragments: stopFragments
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
        let matching = package.manifest.values.filter { $0.path.relativePath == chapter.href }
        let path: EPUBPath
        if matching.count == 1, let manifestPath = matching.first?.path {
            path = EPUBPath(relativePath: manifestPath.relativePath, fragment: chapter.fragment.isEmpty ? nil : chapter.fragment)
        } else {
            path = try EPUBPath.resolve(reference: chapter.href)
        }
        return try package.reader.readExactResource(path, maxBytes: EPUBResourceBudget.chapter)
    }
}
