import Foundation

public enum DirectoryEPUBPackageError: Error, Equatable, Sendable {
    case invalidContainer
    case missingRootfile
    case invalidPackageDocument
    case duplicateManifestID
    case invalidSpineReference
    case readFailed
}

struct EPUBManifestItem: Equatable, Sendable {
    let id: String
    let path: EPUBPath
    let mediaType: String
    let properties: Set<String>
}

struct EPUBSpineItem: Equatable, Sendable {
    let idref: String
    let order: Int
}

struct DirectoryEPUBPackage: Equatable, Sendable {
    let root: URL
    let packageDocument: EPUBPath
    let manifest: [String: EPUBManifestItem]
    let spine: [EPUBSpineItem]

    init(root: URL) throws {
        let canonicalRoot = root.standardizedFileURL
        let containerPath: EPUBPath
        do {
            containerPath = try EPUBPath.resolve(root: canonicalRoot, reference: "META-INF/container.xml")
        } catch EPUBPathError.missingRoot {
            throw ContentError.unavailable(.missing)
        }
        let containerData = try Self.readAvailableFile(containerPath)
        let rootfile = try ContainerDocument.parse(containerData)
        let packageDocument = try EPUBPath.resolve(root: canonicalRoot, reference: rootfile)
        let packageData = try Self.readAvailableFile(packageDocument)
        let parsed = try PackageDocument.parse(packageData)

        var resolvedManifest: [String: EPUBManifestItem] = [:]
        resolvedManifest.reserveCapacity(parsed.manifest.count)
        for item in parsed.manifest {
            let path = try EPUBPath.resolve(
                root: canonicalRoot,
                reference: item.href,
                relativeTo: packageDocument.directory
            )
            resolvedManifest[item.id] = EPUBManifestItem(
                id: item.id,
                path: path,
                mediaType: item.mediaType,
                properties: item.properties
            )
        }
        guard parsed.spine.allSatisfy({ resolvedManifest[$0] != nil }) else {
            throw DirectoryEPUBPackageError.invalidSpineReference
        }

        self.root = canonicalRoot
        self.packageDocument = packageDocument
        manifest = resolvedManifest
        spine = parsed.spine.enumerated().map { EPUBSpineItem(idref: $0.element, order: $0.offset + 1) }
    }

    static func readAvailableFile(_ path: EPUBPath) throws -> Data {
        let availability = BookContentAvailability.inspect(path.url)
        guard availability == .available else {
            throw ContentError.unavailable(availability)
        }
        do {
            return try Data(contentsOf: path.url)
        } catch {
            throw DirectoryEPUBPackageError.readFailed
        }
    }
}

private final class ContainerDocument: NSObject, XMLParserDelegate {
    private static let namespace = "urn:oasis:names:tc:opendocument:xmlns:container"
    private var firstRootfile: String?

    static func parse(_ data: Data) throws -> String {
        let delegate = ContainerDocument()
        let parser = XMLParser(data: data)
        configure(parser, delegate: delegate)
        guard parser.parse() else { throw DirectoryEPUBPackageError.invalidContainer }
        guard let rootfile = delegate.firstRootfile else {
            throw DirectoryEPUBPackageError.missingRootfile
        }
        return rootfile
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard firstRootfile == nil,
              namespaceURI == Self.namespace,
              elementName == "rootfile",
              let fullPath = attributeDict["full-path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              fullPath.isEmpty == false else {
            return
        }
        firstRootfile = fullPath
    }
}

private final class PackageDocument: NSObject, XMLParserDelegate {
    private static let namespace = "http://www.idpf.org/2007/opf"

    struct ManifestEntry {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>
    }

    private(set) var manifest: [ManifestEntry] = []
    private(set) var spine: [String] = []
    private var manifestIDs = Set<String>()
    private var structuralError: DirectoryEPUBPackageError?

    static func parse(_ data: Data) throws -> PackageDocument {
        let delegate = PackageDocument()
        let parser = XMLParser(data: data)
        configure(parser, delegate: delegate)
        guard parser.parse(), delegate.structuralError == nil else {
            throw delegate.structuralError ?? DirectoryEPUBPackageError.invalidPackageDocument
        }
        return delegate
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard structuralError == nil, namespaceURI == Self.namespace else { return }
        switch elementName {
        case "item":
            guard let id = required(attributeDict["id"]),
                  let href = required(attributeDict["href"]),
                  let mediaType = required(attributeDict["media-type"]) else {
                structuralError = .invalidPackageDocument
                parser.abortParsing()
                return
            }
            guard manifestIDs.insert(id).inserted else {
                structuralError = .duplicateManifestID
                parser.abortParsing()
                return
            }
            let properties = Set((attributeDict["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            manifest.append(.init(id: id, href: href, mediaType: mediaType, properties: properties))
        case "itemref":
            guard let idref = required(attributeDict["idref"]) else {
                structuralError = .invalidPackageDocument
                parser.abortParsing()
                return
            }
            spine.append(idref)
        default:
            break
        }
    }

    private func required(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private func configure(_ parser: XMLParser, delegate: XMLParserDelegate) {
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
}
