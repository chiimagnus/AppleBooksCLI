import Foundation

public enum EPUBEncryption: String, Codable, Equatable, Sendable {
    case none
    case fontObfuscationOnly
    case contentEncryptionUnsupported
    case malformedEncryptionMetadata

    private static let fontObfuscationAlgorithm = "http://www.idpf.org/2008/embedding"
    private static let fontMediaTypes: Set<String> = [
        "font/ttf",
        "application/font-sfnt",
        "font/otf",
        "application/vnd.ms-opentype",
        "font/woff",
        "application/font-woff",
        "font/woff2",
    ]

    static func inspect(package: DirectoryEPUBPackage) throws -> EPUBEncryption {
        let encryptionPath: EPUBPath
        do {
            encryptionPath = try EPUBPath.resolve(reference: "META-INF/encryption.xml")
        } catch {
            return .malformedEncryptionMetadata
        }

        guard try package.reader.contains(encryptionPath) else { return .none }
        let data = try package.reader.readExactResource(encryptionPath, maxBytes: EPUBResourceBudget.encryption)
        let entries: [EncryptionEntry]
        do {
            entries = try EncryptionDocument.parse(data)
        } catch {
            return .malformedEncryptionMetadata
        }
        guard entries.isEmpty == false else {
            return .malformedEncryptionMetadata
        }

        for entry in entries {
            guard entry.algorithm == fontObfuscationAlgorithm else {
                return .contentEncryptionUnsupported
            }
            let target: EPUBPath
            do {
                target = try EPUBPath.resolve(reference: entry.uri)
            } catch {
                return .malformedEncryptionMetadata
            }
            guard target.fragment == nil else {
                return .malformedEncryptionMetadata
            }

            let mediaTypes = Set(
                package.manifest.values
                    .filter { $0.path.relativePath == target.relativePath }
                    .map { $0.mediaType.lowercased() }
            )
            guard mediaTypes.count == 1,
                  let mediaType = mediaTypes.first,
                  fontMediaTypes.contains(mediaType) else {
                return .contentEncryptionUnsupported
            }
        }
        return .fontObfuscationOnly
    }
}

private struct EncryptionEntry: Equatable {
    let algorithm: String
    let uri: String
}

private final class EncryptionDocument: NSObject, XMLParserDelegate {
    private static let containerNamespace = "urn:oasis:names:tc:opendocument:xmlns:container"
    private static let encryptionNamespace = "http://www.w3.org/2001/04/xmlenc#"

    private var entries: [EncryptionEntry] = []
    private var sawRoot = false
    private var insideEncryptedData = false
    private var algorithm: String?
    private var uri: String?
    private var malformed = false

    static func parse(_ data: Data) throws -> [EncryptionEntry] {
        let delegate = EncryptionDocument()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.malformed == false, delegate.sawRoot else {
            throw EncryptionDocumentError.invalid
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard malformed == false else { return }
        if sawRoot == false {
            guard namespaceURI == Self.containerNamespace, elementName == "encryption" else {
                malformed = true
                parser.abortParsing()
                return
            }
            sawRoot = true
            return
        }
        if namespaceURI == Self.encryptionNamespace, elementName == "EncryptedData" {
            guard insideEncryptedData == false else {
                malformed = true
                parser.abortParsing()
                return
            }
            insideEncryptedData = true
            algorithm = nil
            uri = nil
            return
        }
        guard insideEncryptedData, namespaceURI == Self.encryptionNamespace else { return }
        switch elementName {
        case "EncryptionMethod":
            guard algorithm == nil,
                  let value = required(attributeDict["Algorithm"]) else {
                malformed = true
                parser.abortParsing()
                return
            }
            algorithm = value
        case "CipherReference":
            guard uri == nil,
                  let value = required(attributeDict["URI"]) else {
                malformed = true
                parser.abortParsing()
                return
            }
            uri = value
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard namespaceURI == Self.encryptionNamespace,
              elementName == "EncryptedData",
              insideEncryptedData else {
            return
        }
        guard let algorithm, let uri else {
            malformed = true
            parser.abortParsing()
            return
        }
        entries.append(EncryptionEntry(algorithm: algorithm, uri: uri))
        insideEncryptedData = false
        self.algorithm = nil
        self.uri = nil
    }

    private func required(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private enum EncryptionDocumentError: Error {
        case invalid
    }
}
