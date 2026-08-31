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
    private var depth = 0
    private var rootfilesDepth: Int?
    private var sawContainer = false
    private var sawRootfiles = false
    private var structuralError: DirectoryEPUBPackageError?

    static func parse(_ data: Data) throws -> String {
        let delegate = ContainerDocument()
        let parser = XMLParser(data: data)
        configure(parser, delegate: delegate)
        guard parser.parse(), delegate.structuralError == nil, delegate.sawContainer else {
            throw delegate.structuralError ?? DirectoryEPUBPackageError.invalidContainer
        }
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
        guard structuralError == nil else { return }
        if depth == 0 {
            guard namespaceURI == Self.namespace, elementName == "container" else {
                fail(parser)
                return
            }
            sawContainer = true
            depth += 1
            return
        }

        if namespaceURI == Self.namespace {
            switch elementName {
            case "rootfiles":
                guard depth == 1, sawRootfiles == false else {
                    fail(parser)
                    return
                }
                sawRootfiles = true
                rootfilesDepth = depth + 1
            case "rootfile":
                guard rootfilesDepth == depth,
                      let fullPath = attributeDict["full-path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      fullPath.isEmpty == false else {
                    fail(parser)
                    return
                }
                if firstRootfile == nil { firstRootfile = fullPath }
            default:
                break
            }
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if namespaceURI == Self.namespace,
           elementName == "rootfiles",
           rootfilesDepth == depth {
            rootfilesDepth = nil
        }
        depth = max(0, depth - 1)
    }

    private func fail(_ parser: XMLParser) {
        structuralError = .invalidContainer
        parser.abortParsing()
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
    private var depth = 0
    private var manifestDepth: Int?
    private var spineDepth: Int?
    private var sawPackage = false
    private var sawManifest = false
    private var sawSpine = false
    private var structuralError: DirectoryEPUBPackageError?

    static func parse(_ data: Data) throws -> PackageDocument {
        let delegate = PackageDocument()
        let parser = XMLParser(data: data)
        configure(parser, delegate: delegate)
        guard parser.parse(),
              delegate.structuralError == nil,
              delegate.sawPackage,
              delegate.sawManifest,
              delegate.sawSpine else {
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
        guard structuralError == nil else { return }
        if depth == 0 {
            guard namespaceURI == Self.namespace, elementName == "package" else {
                fail(.invalidPackageDocument, parser: parser)
                return
            }
            sawPackage = true
            depth += 1
            return
        }

        if namespaceURI == Self.namespace {
            switch elementName {
            case "manifest":
                guard depth == 1, sawManifest == false else {
                    fail(.invalidPackageDocument, parser: parser)
                    return
                }
                sawManifest = true
                manifestDepth = depth + 1
            case "spine":
                guard depth == 1, sawSpine == false else {
                    fail(.invalidPackageDocument, parser: parser)
                    return
                }
                sawSpine = true
                spineDepth = depth + 1
            case "item":
                guard manifestDepth == depth,
                      let id = required(attributeDict["id"]),
                      let href = required(attributeDict["href"]),
                      let mediaType = required(attributeDict["media-type"]) else {
                    fail(.invalidPackageDocument, parser: parser)
                    return
                }
                guard manifestIDs.insert(id).inserted else {
                    fail(.duplicateManifestID, parser: parser)
                    return
                }
                let properties = Set((attributeDict["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                manifest.append(.init(id: id, href: href, mediaType: mediaType, properties: properties))
            case "itemref":
                guard spineDepth == depth,
                      let idref = required(attributeDict["idref"]) else {
                    fail(.invalidPackageDocument, parser: parser)
                    return
                }
                spine.append(idref)
            default:
                break
            }
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if namespaceURI == Self.namespace, elementName == "manifest", manifestDepth == depth {
            manifestDepth = nil
        }
        if namespaceURI == Self.namespace, elementName == "spine", spineDepth == depth {
            spineDepth = nil
        }
        depth = max(0, depth - 1)
    }

    private func fail(_ error: DirectoryEPUBPackageError, parser: XMLParser) {
        structuralError = error
        parser.abortParsing()
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
