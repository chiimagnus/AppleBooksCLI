import Foundation

// A source position, not a presentation-text offset. The generation must be rechecked before writing.
struct EPUBAnnotationSelection: Equatable, Sendable {
    let chapterOrder: Int
    let resourcePath: String
    let selectedText: String
    let cfi: String
    let sourceGeneration: CursorGenerationComponent
    let bookIdentity: BookResourceTarget?
}

enum EPUBAnnotationLocatorError: Error, Equatable {
    case invalidText
    case invalidOccurrence
    case bookNotFound
    case unsupportedSource
    case chapterNotFound
    case fragmentNotFound
    case invalidXHTML
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
                document = try EPUBAnnotationDocument.parse(resource)
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
    private var markers: [String: Int] = [:]
    private var duplicateIDs = false
    private var bodyCount = 0
    private var rootIsHTML = false
    private var count = 0
    private var group = 0
    private var pending = ""
    private var decodedUTF8Bytes = 0
    private var tooComplex = false

    static func parse(_ data: Data) throws -> EPUBAnnotationDocument {
        let document = EPUBAnnotationDocument()
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
        let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        let invisible = Self.excluded.contains(tag) || attributes["hidden"] != nil ||
            attributes["aria-hidden"]?.lowercased() == "true" ||
            style.contains("display:none") || style.contains("visibility:hidden")
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
