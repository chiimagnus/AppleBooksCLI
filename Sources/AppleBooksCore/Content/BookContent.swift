import Darwin
import Foundation

public enum BookContentError: Error, Equatable, Sendable {
    case chapterNotFound
}

public final class BookContent {
    let package: DirectoryEPUBPackage
    private let navigation: EPUBNavigation

    public init(root: URL) throws {
        let canonicalRoot = root.standardizedFileURL
        guard canonicalRoot.pathExtension.lowercased() == "epub" else {
            throw ContentError.unsupportedFormat
        }
        var metadata = stat()
        guard lstat(canonicalRoot.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw ContentError.unavailable(.missing)
            }
            throw ContentError.unavailable(.unknown)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ContentError.unsupportedFormat
        }
        let availability = BookContentAvailability.inspect(canonicalRoot)
        guard availability == .available else {
            throw ContentError.unavailable(availability)
        }

        let package = try DirectoryEPUBPackage(root: canonicalRoot)
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
            path = EPUBPath(relativePath: manifestPath.relativePath, fragment: chapter.fragment.isEmpty ? nil : chapter.fragment, url: manifestPath.url)
        } else {
            path = try EPUBPath.resolve(root: package.root, reference: chapter.href)
        }
        return try DirectoryEPUBPackage.readAvailableFile(path)
    }
}
