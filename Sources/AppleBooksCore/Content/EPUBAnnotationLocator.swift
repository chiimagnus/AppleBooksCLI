import Foundation

// A source position, not a presentation-text offset. The generation must be rechecked before writing.
struct EPUBAnnotationSelection: Equatable, Sendable {
    let chapterOrder: Int
    let resourcePath: String
    let selectedText: String
    let representativeText: String
    let cfi: String
    let sourceGeneration: CursorGenerationComponent
    let bookIdentity: BookResourceTarget?
}

public enum EPUBAnnotationLocatorError: Error, Equatable, Sendable {
    case invalidText
    case invalidOccurrence
    case bookNotFound
    case unsupportedSource
    case chapterNotFound
    case fragmentNotFound
    case invalidXHTML
    case ambiguousVisibility
    case noMatch
    case ambiguous(Int)
    case ambiguousSpine
    case sourceChanged
    case tooComplex
}

struct EPUBAnnotationLocator {
    let content: BookContent
    let bookIdentity: BookResourceTarget?

    init(content: BookContent) {
        self.content = content
        bookIdentity = nil
    }

    init(assetID: String, bookQueries: BookQueries, configuration: AppleBooksConfiguration) throws {
        guard PublicStableIdentityPolicy.isEligible(assetID),
              let target = try bookQueries.uniqueResourceTarget(assetID: assetID),
              target.assetID == assetID else {
            throw EPUBAnnotationLocatorError.bookNotFound
        }
        guard target.contentType != 3 else { throw EPUBAnnotationLocatorError.unsupportedSource }
        let resolution = EPUBSourceResolver.resolve(for: target, configuration: configuration)
        guard resolution.selectedSource == .current, let reader = resolution.reader else {
            throw EPUBAnnotationLocatorError.unsupportedSource
        }
        content = try BookContent(reader: reader)
        bookIdentity = target
    }

    func locate(
        _ text: String,
        chapterOrder: Int? = nil,
        prefix: String? = nil,
        suffix: String? = nil,
        occurrence: Int? = nil
    ) throws -> EPUBAnnotationSelection {
        guard text.isEmpty == false,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              text.utf8.count <= EPUBResourceBudget.chapter else {
            throw EPUBAnnotationLocatorError.invalidText
        }
        if let occurrence, (chapterOrder == nil || occurrence < 1) {
            throw EPUBAnnotationLocatorError.invalidOccurrence
        }
        let chapters = try content.listChapters()
        let selected: [Chapter]
        if let chapterOrder {
            guard let chapter = chapters.first(where: { $0.order == chapterOrder }) else {
                throw EPUBAnnotationLocatorError.chapterNotFound
            }
            selected = [chapter]
        } else {
            selected = chapters
        }
        var exact: [EPUBAnnotationSelection] = []
        var relaxed: [EPUBAnnotationSelection] = []
        var seenExact = Set<String>()
        var seenRelaxed = Set<String>()
        var spineByResource: [String: [Int]] = [:]
        for index in content.package.spine.indices {
            let item = content.package.spine[index]
            if let href = content.package.manifest[item.idref]?.path.relativePath {
                spineByResource[href, default: []].append(index)
            }
        }
        var cached: (href: String, generation: CursorGenerationComponent, document: EPUBAnnotationDocument)?
        for chapter in selected {
            let spineIndices = spineByResource[chapter.href] ?? []
            guard spineIndices.count == 1, let spineIndex = spineIndices.first else {
                throw EPUBAnnotationLocatorError.ambiguousSpine
            }
            let spineCFI = try cfiPrefix(spineIndex: spineIndex)
            let generation = try content.chapterCursorGenerationComponent(for: chapter)
            let document: EPUBAnnotationDocument
            if let cached, cached.href == chapter.href {
                guard cached.generation == generation else { throw EPUBAnnotationLocatorError.sourceChanged }
                document = cached.document
            } else {
                let resource = try content.readChapterBytes(chapter)
                let initial = try EPUBAnnotationDocument.parse(resource)
                let selectors = try hiddenSelectors(in: initial, chapter: chapter)
                document = selectors.isEmpty
                    ? initial
                    : try EPUBAnnotationDocument.parse(resource, hiddenSelectors: selectors)
                cached = (chapter.href, generation, document)
            }
            let fragments = Set(chapters.filter { $0.href == chapter.href && $0.fragment.isEmpty == false }.map(\.fragment))
            let leaves = try document.leaves(from: chapter.fragment, otherFragments: fragments)
            let runs = EPUBAnnotationRun.make(from: leaves)
            let allowsWhitespaceFallback = text.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0x3000
            }
            for run in runs {
                for useWhitespaceFallback in (allowsWhitespaceFallback ? [false, true] : [false]) {
                    let ranges = run.matches(
                        text, prefix: prefix, suffix: suffix, normalizeWhitespace: useWhitespaceFallback
                    )
                    for range in ranges {
                        let cfi = try run.cfi(for: range, spinePrefix: spineCFI)
                        guard CFIResourcePolicy.allowsStructuralParsing(cfi) else {
                            throw EPUBAnnotationLocatorError.tooComplex
                        }
                        let match = EPUBAnnotationSelection(
                            chapterOrder: chapter.order,
                            resourcePath: chapter.href,
                            selectedText: (run.text as NSString).substring(with: range),
                            representativeText: run.text,
                            cfi: cfi,
                            sourceGeneration: generation,
                            bookIdentity: bookIdentity
                        )
                        if useWhitespaceFallback {
                            if seenRelaxed.insert(cfi).inserted { relaxed.append(match) }
                        } else if seenExact.insert(cfi).inserted {
                            exact.append(match)
                        }
                        guard exact.count <= EPUBStructureBudget.maximumXHTMLNodes,
                              relaxed.count <= EPUBStructureBudget.maximumXHTMLNodes else {
                            throw EPUBAnnotationLocatorError.tooComplex
                        }
                    }
                }
            }
            guard try content.chapterCursorGenerationComponent(for: chapter) == generation else {
                throw EPUBAnnotationLocatorError.sourceChanged
            }
        }
        let matches = exact.isEmpty ? relaxed : exact
        if let occurrence {
            guard occurrence <= matches.count else { throw EPUBAnnotationLocatorError.noMatch }
            return matches[occurrence - 1]
        }
        guard matches.isEmpty == false else { throw EPUBAnnotationLocatorError.noMatch }
        guard matches.count == 1 else { throw EPUBAnnotationLocatorError.ambiguous(matches.count) }
        return matches[0]
    }

    private func hiddenSelectors(
        in document: EPUBAnnotationDocument, chapter: Chapter
    ) throws -> [EPUBCSSHiddenSelector] {
        var selectors: [EPUBCSSHiddenSelector] = []
        for embedded in document.embeddedStyles {
            try Self.collectHiddenSelectors(embedded, into: &selectors)
        }
        guard document.stylesheetLinks.count <= 64 else { throw EPUBAnnotationLocatorError.tooComplex }
        var remaining = EPUBResourceBudget.navigation
        var seen = Set<String>()
        let base = try EPUBPath.resolve(reference: chapter.href)
        for reference in document.stylesheetLinks {
            let path = try EPUBPath.resolve(reference: reference, relativeTo: base.directory)
            guard seen.insert(path.relativePath).inserted else { continue }
            let data = try content.package.reader.readExactResource(path, maxBytes: remaining)
            remaining -= data.count
            guard let css = String(data: data, encoding: .utf8) else {
                throw EPUBAnnotationLocatorError.ambiguousVisibility
            }
            try Self.collectHiddenSelectors(css, into: &selectors)
        }
        return selectors
    }

    private static func collectHiddenSelectors(
        _ css: String, into selectors: inout [EPUBCSSHiddenSelector]
    ) throws {
        let withoutComments = css.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#, with: "", options: [.regularExpression]
        )
        guard withoutComments.lowercased().contains("@import") == false else {
            throw EPUBAnnotationLocatorError.ambiguousVisibility
        }
        for rule in withoutComments.split(separator: "}") {
            guard let opening = rule.lastIndex(of: "{") else { continue }
            let declarations = rule[rule.index(after: opening)...].lowercased().filter { !$0.isWhitespace }
            let hides = ["display:none", "visibility:hidden", "visibility:collapse",
                         "content-visibility:hidden", "color:transparent", "clip-path:"]
                .contains { declarations.contains($0) }
                || declarations.contains("opacity:0;")
                || declarations.contains("opacity:0!important")
                || declarations.hasSuffix("opacity:0")
            guard hides else { continue }
            let rawSelectors = rule[..<opening].split(separator: "{").last ?? ""
            for raw in rawSelectors.split(separator: ",") {
                guard let selector = EPUBCSSHiddenSelector.parse(String(raw)) else {
                    throw EPUBAnnotationLocatorError.ambiguousVisibility
                }
                selectors.append(selector)
                guard selectors.count <= 256 else { throw EPUBAnnotationLocatorError.tooComplex }
            }
        }
    }

    private func cfiPrefix(spineIndex: Int) throws -> String {
        let package = content.package
        guard package.spinePackageCFIStep > 0,
              package.spineItemCFISteps.indices.contains(spineIndex),
              package.spineItemCFISteps[spineIndex] > 0 else {
            throw EPUBAnnotationLocatorError.ambiguousSpine
        }
        let assertion = package.spineItemCFIAssertions[spineIndex]
        return "/\(package.spinePackageCFIStep)/\(package.spineItemCFISteps[spineIndex])[\(CFIStep.escape(assertion))]!"
    }
}

private struct CFIStep: Equatable {
    let index: Int
    let assertion: String?

    var encoded: String {
        "/\(index)" + (assertion.map { "[\(Self.escape($0))]" } ?? "")
    }

    static func escape(_ value: String) -> String {
        var output = ""
        for character in value {
            if "^[](),;=!".contains(character) { output.append("^") }
            output.append(character)
        }
        return output
    }
}

private struct EPUBTextLeaf {
    let text: String
    let path: [CFIStep]
    let group: Int
    let textOffset: Int
}

private struct EPUBCSSHiddenSelector {
    let tag: String?
    let id: String?
    let classes: Set<String>

    static func parse(_ raw: String) -> Self? {
        let chars = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard chars.isEmpty == false else { return nil }
        var position = 0
        var tag: String?
        var id: String?
        var classes = Set<String>()
        while position < chars.count {
            let prefix = chars[position]
            let kind: Character
            if prefix == "." || prefix == "#" {
                kind = prefix
                position += 1
            } else if position == 0 {
                kind = "t"
            } else {
                return nil
            }
            let start = position
            while position < chars.count {
                let char = chars[position]
                guard char.isLetter || char.isNumber || char == "_" || char == "-" else { break }
                position += 1
            }
            guard start < position else { return nil }
            let name = String(chars[start..<position])
            switch kind {
            case ".": classes.insert(name)
            case "#":
                guard id == nil else { return nil }
                id = name
            default: tag = name.lowercased()
            }
        }
        return Self(tag: tag, id: id, classes: classes)
    }

    func matches(tag elementTag: String, attributes: [String: String]) -> Bool {
        if let tag, tag != elementTag { return false }
        if let id, id != attributes["id"] { return false }
        let present = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        return present.isSuperset(of: classes)
    }
}

private final class EPUBAnnotationDocument: NSObject, XMLParserDelegate {
    private struct Frame {
        let tag: String
        let path: [CFIStep]
        let excluded: Bool
        var elementChildren = 0
        var textOffset = 0
    }

    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "li", "main", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    private static let excluded: Set<String> = ["head", "script", "style", "title", "nav", "noscript", "svg", "math"]
    private static let nonTextBoundaries: Set<String> = ["img", "br", "audio", "video", "object", "iframe"]

    private var frames: [Frame] = []
    private(set) var leaves: [EPUBTextLeaf] = []
    private(set) var embeddedStyles: [String] = []
    private(set) var stylesheetLinks: [String] = []
    private var markers: [String: Int] = [:]
    private var duplicateIDs = false
    private var bodyCount = 0
    private var rootIsHTML = false
    private var count = 0
    private var group = 0
    private var pending = ""
    private var decodedUTF8Bytes = 0
    private var tooComplex = false
    private let hiddenSelectors: [EPUBCSSHiddenSelector]

    private init(hiddenSelectors: [EPUBCSSHiddenSelector]) {
        self.hiddenSelectors = hiddenSelectors
        super.init()
    }

    static func parse(
        _ data: Data, hiddenSelectors: [EPUBCSSHiddenSelector] = []
    ) throws -> EPUBAnnotationDocument {
        let document = EPUBAnnotationDocument(hiddenSelectors: hiddenSelectors)
        let parser = XMLParser(data: data)
        parser.delegate = document
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), document.tooComplex == false,
              document.rootIsHTML, document.bodyCount == 1,
              document.duplicateIDs == false else {
            if document.tooComplex { throw EPUBAnnotationLocatorError.tooComplex }
            throw EPUBAnnotationLocatorError.invalidXHTML
        }
        return document
    }

    func leaves(from fragment: String, otherFragments: Set<String>) throws -> [EPUBTextLeaf] {
        guard fragment.isEmpty == false else { return leaves }
        guard let start = markers[fragment] else { throw EPUBAnnotationLocatorError.fragmentNotFound }
        let end = otherFragments.compactMap { markers[$0] }.filter { $0 > start }.min() ?? leaves.count
        return Array(leaves[start..<end])
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]
    ) {
        flush()
        count += 1
        guard count <= EPUBStructureBudget.maximumXHTMLNodes,
              frames.count < EPUBStructureBudget.maximumNestingDepth else {
            tooComplex = true
            parser.abortParsing()
            return
        }
        let tag = elementName.lowercased()
        if frames.isEmpty { rootIsHTML = tag == "html" }
        let path: [CFIStep]
        if frames.isEmpty {
            path = []
        } else {
            let last = frames.count - 1
            frames[last].elementChildren += 1
            frames[last].textOffset = 0
            path = frames[last].path + [CFIStep(index: frames[last].elementChildren * 2, assertion: attributes["id"])]
        }
        if tag == "body" { bodyCount += 1 }
        if tag == "style" { embeddedStyles.append("") }
        if tag == "link", attributes["rel"]?.lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet") == true {
            stylesheetLinks.append(attributes["href"] ?? "")
        }
        let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        let invisible = Self.excluded.contains(tag) || attributes["hidden"] != nil ||
            attributes["aria-hidden"]?.lowercased() == "true" ||
            style.contains("display:none") || style.contains("visibility:hidden") ||
            hiddenSelectors.contains(where: { $0.matches(tag: tag, attributes: attributes) })
        let excluded = (frames.last?.excluded ?? false) || invisible
        if excluded == false, bodyCount > 0,
           let id = attributes["id"], id.isEmpty == false {
            if markers.updateValue(leaves.count, forKey: id) != nil { duplicateIDs = true }
        }
        if Self.blocks.contains(tag) || Self.nonTextBoundaries.contains(tag) || invisible { group += 1 }
        frames.append(Frame(tag: tag, path: path, excluded: excluded))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            parser.abortParsing()
            return
        }
        append(string, parser: parser)
    }

    private func append(_ string: String, parser: XMLParser) {
        let count = string.utf8.count
        guard count <= EPUBResourceBudget.chapter - decodedUTF8Bytes else {
            tooComplex = true
            parser.abortParsing()
            return
        }
        decodedUTF8Bytes += count
        pending += string
    }
    func parser(_ parser: XMLParser, foundComment comment: String) { flush() }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        flush()
        if let frame = frames.popLast(),
           Self.blocks.contains(frame.tag) || Self.nonTextBoundaries.contains(frame.tag) ||
           Self.excluded.contains(frame.tag) || frame.excluded {
            group += 1
        }
    }

    private func flush() {
        guard pending.isEmpty == false, frames.isEmpty == false else { pending = ""; return }
        let last = frames.count - 1
        let path = frames[last].path + [CFIStep(index: frames[last].elementChildren * 2 + 1, assertion: nil)]
        let offset = frames[last].textOffset
        frames[last].textOffset += pending.utf16.count
        if frames[last].tag == "style", embeddedStyles.isEmpty == false {
            embeddedStyles[embeddedStyles.count - 1] += pending
        }
        if frames[last].excluded == false, frames.contains(where: { $0.tag == "body" }) {
            leaves.append(EPUBTextLeaf(text: pending, path: path, group: group, textOffset: offset))
            count += 1
        }
        pending = ""
    }
}

private struct EPUBAnnotationRun {
    struct Segment {
        let start: Int
        let end: Int
        let path: [CFIStep]
        let textOffset: Int
    }
    let text: String
    let segments: [Segment]

    func matches(
        _ query: String, prefix: String?, suffix: String?, normalizeWhitespace: Bool
    ) -> [NSRange] {
        let source: NSString
        let needle: String
        let mapping: [NSRange]
        if normalizeWhitespace {
            let normalized = Self.normalized(text)
            source = normalized.text as NSString
            mapping = normalized.mapping
            needle = Self.normalized(query).text
        } else {
            source = text as NSString
            mapping = []
            needle = query
        }
        guard needle.isEmpty == false, source.length >= needle.utf16.count else { return [] }
        var matches: [NSRange] = []
        var offset = 0
        while offset < source.length {
            let found = source.range(
                of: needle,
                options: .literal,
                range: NSRange(location: offset, length: source.length - offset)
            )
            if found.location == NSNotFound { break }
            let actual: NSRange
            if normalizeWhitespace {
                let first = mapping[found.location]
                let last = mapping[found.location + found.length - 1]
                actual = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            } else {
                actual = found
            }
            if contextMatches(prefix: prefix, suffix: suffix, range: actual) {
                matches.append(actual)
                if matches.count > EPUBStructureBudget.maximumXHTMLNodes { break }
            }
            offset = found.location + 1
        }
        guard matches.isEmpty == false else { return [] }
        let wanted = Set(matches.flatMap { [$0.location, NSMaxRange($0)] })
        var boundaries: Set<Int> = []
        var index = 0
        for character in text {
            if wanted.contains(index) { boundaries.insert(index) }
            index += character.utf16.count
        }
        if wanted.contains(index) { boundaries.insert(index) }
        return matches.filter { boundaries.contains($0.location) && boundaries.contains(NSMaxRange($0)) }
    }

    func cfi(for range: NSRange, spinePrefix: String) throws -> String {
        guard range.length > 0,
              let start = segments.first(where: { $0.start <= range.location && range.location < $0.end }),
              let end = segments.first(where: { $0.start <= NSMaxRange(range) - 1 && NSMaxRange(range) - 1 < $0.end }) else {
            throw EPUBAnnotationLocatorError.noMatch
        }
        let startOffset = start.textOffset + range.location - start.start
        let endOffset = end.textOffset + NSMaxRange(range) - end.start
        let common = zip(start.path, end.path).prefix(while: { $0 == $1 }).count
        let shared = start.path.prefix(common).map(\.encoded).joined()
        if start.path == end.path {
            return "epubcfi(\(spinePrefix)\(shared),:\(startOffset),:\(endOffset))"
        }
        let startTail = start.path.dropFirst(common).map(\.encoded).joined()
        let endTail = end.path.dropFirst(common).map(\.encoded).joined()
        return "epubcfi(\(spinePrefix)\(shared),\(startTail):\(startOffset),\(endTail):\(endOffset))"
    }

    private func contextMatches(prefix: String?, suffix: String?, range: NSRange) -> Bool {
        let source = text as NSString
        if let prefix, prefix.isEmpty == false {
            guard range.location >= prefix.utf16.count else { return false }
            let before = source.substring(with: NSRange(location: range.location - prefix.utf16.count, length: prefix.utf16.count))
            guard before == prefix else { return false }
        }
        if let suffix, suffix.isEmpty == false {
            guard NSMaxRange(range) <= source.length - suffix.utf16.count else { return false }
            let after = source.substring(with: NSRange(location: NSMaxRange(range), length: suffix.utf16.count))
            guard after == suffix else { return false }
        }
        return true
    }

    private static func normalized(_ source: String) -> (text: String, mapping: [NSRange]) {
        var units: [UInt16] = []
        var mapping: [NSRange] = []
        var offset = 0
        for scalar in source.unicodeScalars {
            let count = scalar.utf16.count
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0x3000 {
                if units.last == 32 {
                    mapping[mapping.count - 1].length += count
                } else {
                    units.append(32)
                    mapping.append(NSRange(location: offset, length: count))
                }
            } else {
                for (index, codeUnit) in String(scalar).utf16.enumerated() {
                    units.append(codeUnit)
                    mapping.append(NSRange(location: offset + index, length: 1))
                }
            }
            offset += count
        }
        return (String(decoding: units, as: UTF16.self), mapping)
    }

    static func make(from leaves: [EPUBTextLeaf]) -> [Self] {
        var runs: [Self] = []
        var text = ""
        var segments: [Segment] = []
        var lastGroup: Int?
        var offset = 0
        for leaf in leaves {
            if lastGroup != leaf.group && lastGroup != nil {
                if !segments.isEmpty { runs.append(Self(text: text, segments: segments)) }
                text = ""
                segments = []
                offset = 0
            }
            lastGroup = leaf.group
            let length = leaf.text.utf16.count
            segments.append(Segment(start: offset, end: offset + length, path: leaf.path, textOffset: leaf.textOffset))
            text += leaf.text
            offset += length
        }
        if !segments.isEmpty { runs.append(Self(text: text, segments: segments)) }
        return runs
    }
}
