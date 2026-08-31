import Foundation

public enum EPUBMetadataError: Error, Equatable, Sendable {
    case invalidPackageMetadata
}

public struct EPUBMetadata: Equatable, Sendable {
    public let title: String?
    public let creator: String?
    public let identifiers: [String]
    public let isbn: String?
    public let language: String?
    public let publisher: String?
    public let publicationDate: String?
    public let rights: String?
    public let subjects: [String]
    let coverItemID: String?

    public func supplementing(_ book: Book) -> BookMetadataEnrichment {
        BookMetadataEnrichment(
            isbn: isbn,
            language: book.language == nil ? language : nil,
            publisher: publisher,
            publicationDate: book.releaseDate == nil ? publicationDate : nil,
            rights: rights,
            subjects: subjects
        )
    }

    static func read(package: DirectoryEPUBPackage) throws -> EPUBMetadata {
        let opfData = try DirectoryEPUBPackage.readAvailableFile(package.packageDocument)
        let opf = try OPFMetadataDocument.parse(opfData)
        let iTunes = readITunesMetadata(root: package.root)
        return EPUBMetadata(
            title: opf.title ?? iTunes?.title,
            creator: opf.creator ?? iTunes?.creator,
            identifiers: opf.identifiers,
            isbn: opf.isbn,
            language: opf.language,
            publisher: opf.publisher ?? iTunes?.publisher,
            publicationDate: opf.publicationDate,
            rights: opf.rights,
            subjects: opf.subjects,
            coverItemID: opf.coverItemID
        )
    }

    private static func readITunesMetadata(root: URL) -> ITunesMetadata? {
        do {
            let path = try EPUBPath.resolve(root: root, reference: "iTunesMetadata.plist")
            guard BookContentAvailability.inspect(path.url) == .available else { return nil }
            let data = try DirectoryEPUBPackage.readAvailableFile(path)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            return ITunesMetadata(
                title: dictionary["itemName"] as? String,
                creator: dictionary["artistName"] as? String,
                publisher: dictionary["publisher"] as? String
            )
        } catch {
            return nil
        }
    }
}

public struct BookMetadataEnrichment: Equatable, Sendable {
    public let isbn: String?
    public let language: String?
    public let publisher: String?
    public let publicationDate: String?
    public let rights: String?
    public let subjects: [String]

    public init(
        isbn: String?,
        language: String?,
        publisher: String?,
        publicationDate: String?,
        rights: String?,
        subjects: [String]
    ) {
        self.isbn = isbn
        self.language = language
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.rights = rights
        self.subjects = subjects
    }
}

public extension BookContent {
    func metadata() throws -> EPUBMetadata {
        try EPUBMetadata.read(package: package)
    }
}

private struct ITunesMetadata {
    let title: String?
    let creator: String?
    let publisher: String?
}

private final class OPFMetadataDocument: NSObject, XMLParserDelegate {
    private static let opfNamespace = "http://www.idpf.org/2007/opf"
    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"

    private(set) var title: String?
    private(set) var creator: String?
    private(set) var identifiers: [String] = []
    private(set) var isbn: String?
    private(set) var language: String?
    private(set) var publisher: String?
    private(set) var publicationDate: String?
    private(set) var rights: String?
    private(set) var subjects: [String] = []
    private(set) var coverItemID: String?

    private var depth = 0
    private var metadataDepth: Int?
    private var currentElement: String?
    private var currentText = ""
    private var currentIdentifierExplicitISBN = false
    private var sawPackage = false

    static func parse(_ data: Data) throws -> OPFMetadataDocument {
        let delegate = OPFMetadataDocument()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.sawPackage else {
            throw EPUBMetadataError.invalidPackageMetadata
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
        if depth == 0 {
            sawPackage = namespaceURI == Self.opfNamespace && elementName == "package"
        }
        if namespaceURI == Self.opfNamespace, elementName == "metadata", depth == 1 {
            metadataDepth = depth + 1
        } else if metadataDepth != nil, namespaceURI == Self.dcNamespace,
                  ["title", "creator", "identifier", "language", "publisher", "date", "rights", "subject"].contains(elementName) {
            currentElement = elementName
            currentText = ""
            if elementName == "identifier" {
                currentIdentifierExplicitISBN = attributeDict.contains { key, value in
                    let localKey = key.split(separator: ":").last?.lowercased()
                    return (localKey == "scheme" || localKey == "role")
                        && value.localizedCaseInsensitiveContains("isbn")
                }
            }
        } else if metadataDepth != nil, namespaceURI == Self.opfNamespace, elementName == "meta",
                  attributeDict["name"]?.lowercased() == "cover",
                  let content = cleaned(attributeDict["content"]) {
            coverItemID = coverItemID ?? content
        }
        depth += 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if namespaceURI == Self.dcNamespace, currentElement == elementName {
            if let value = cleaned(currentText) {
                switch elementName {
                case "title": title = title ?? value
                case "creator": creator = creator ?? value
                case "identifier":
                    identifiers.append(value)
                    if isbn == nil, let candidate = canonicalISBN(value, explicitlyISBN: currentIdentifierExplicitISBN) {
                        isbn = candidate
                    }
                case "language": language = language ?? value
                case "publisher": publisher = publisher ?? value
                case "date": publicationDate = publicationDate ?? value
                case "rights": rights = rights ?? value
                case "subject": subjects.append(value)
                default: break
                }
            }
            currentElement = nil
            currentText = ""
            currentIdentifierExplicitISBN = false
        }
        if namespaceURI == Self.opfNamespace, elementName == "metadata", metadataDepth == depth {
            metadataDepth = nil
        }
        depth = max(0, depth - 1)
    }
}

private func cleaned(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
        return nil
    }
    return value
}

private func canonicalISBN(_ raw: String, explicitlyISBN: Bool) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["urn:isbn:", "isbn-13:", "isbn-10:", "isbn:"] where value.lowercased().hasPrefix(prefix) {
        value.removeFirst(prefix.count)
        break
    }
    let compact = value.filter { $0 != "-" && $0.isWhitespace == false }.uppercased()
    if validISBN13(compact) || validISBN10(compact) { return compact }
    if explicitlyISBN,
       (compact.count == 13 && compact.allSatisfy(\.isNumber)
        || compact.count == 10 && compact.dropLast().allSatisfy(\.isNumber) && (compact.last?.isNumber == true || compact.last == "X")) {
        return compact
    }
    return nil
}

private func validISBN13(_ value: String) -> Bool {
    guard value.count == 13, value.allSatisfy(\.isNumber) else { return false }
    let digits = value.compactMap(\.wholeNumberValue)
    guard digits.count == 13 else { return false }
    let sum = digits.enumerated().reduce(0) { partial, item in
        partial + item.element * (item.offset.isMultiple(of: 2) ? 1 : 3)
    }
    return sum.isMultiple(of: 10)
}

private func validISBN10(_ value: String) -> Bool {
    guard value.count == 10 else { return false }
    let characters = Array(value)
    var sum = 0
    for index in 0..<10 {
        let digit: Int
        if index == 9, characters[index] == "X" {
            digit = 10
        } else if let number = characters[index].wholeNumberValue {
            digit = number
        } else {
            return false
        }
        sum += (10 - index) * digit
    }
    return sum.isMultiple(of: 11)
}
