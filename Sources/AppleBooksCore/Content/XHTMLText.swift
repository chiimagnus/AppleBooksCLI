import Foundation
import SwiftSoup

public enum XHTMLTextError: Error, Equatable, Sendable {
    case invalidDocument
    case fragmentNotFound
}

struct XHTMLTextPage: Equatable, Sendable {
    let content: String
    let returnedGraphemes: Int
    let hasMore: Bool
    let inspectedSourceGraphemes: Int
}

enum XHTMLText {
    private static let excludedTags: Set<String> = ["head", "title", "script", "style"]
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    static func extract(_ data: Data, fragment: String?, stopFragments: Set<String> = []) throws -> String {
        let document: Document
        do {
            document = try SwiftSoup.parse(data, "")
        } catch {
            throw XHTMLTextError.invalidDocument
        }
        guard let body = document.body() else { throw XHTMLTextError.invalidDocument }

        var state = TraversalState(
            requestedFragment: fragment?.isEmpty == false ? fragment : nil,
            stopFragments: stopFragments
        )
        try visitIteratively(body, state: &state)
        if state.requestedFragment != nil, state.foundStart == false {
            throw XHTMLTextError.fragmentNotFound
        }
        return state.output.value
    }

    static func page(
        _ data: Data,
        fragment: String?,
        stopFragments: Set<String> = [],
        offset: Int,
        maximumGraphemes: Int,
        maximumUTF8Bytes: Int
    ) throws -> XHTMLTextPage {
        guard offset >= 0, maximumGraphemes > 0, maximumUTF8Bytes > 0 else {
            throw CursorPaginationError.internalContractFailure
        }
        let document: Document
        do {
            document = try SwiftSoup.parse(data, "")
        } catch {
            throw XHTMLTextError.invalidDocument
        }
        guard let body = document.body() else { throw XHTMLTextError.invalidDocument }

        var state = PageTraversalState(
            requestedFragment: fragment?.isEmpty == false ? fragment : nil,
            stopFragments: stopFragments,
            offset: offset,
            maximumGraphemes: maximumGraphemes,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        try visitPageIteratively(body, state: &state)
        if state.requestedFragment != nil, state.foundStart == false {
            throw XHTMLTextError.fragmentNotFound
        }
        return XHTMLTextPage(
            content: state.output.content,
            returnedGraphemes: state.output.returnedGraphemes,
            hasMore: state.output.hasMore,
            inspectedSourceGraphemes: state.output.inspectedSourceGraphemes
        )
    }

    private static func visitIteratively(_ root: Node, state: inout TraversalState) throws {
        var events: [TraversalEvent] = [.enter(root, depth: 1)]
        var visitedNodes = 0

        while let event = events.popLast() {
            if state.stopped { break }
            switch event {
            case let .enter(node, depth):
                guard visitedNodes < EPUBStructureBudget.maximumXHTMLNodes else {
                    throw EPUBResourceError.tooComplex
                }
                visitedNodes += 1

                if let element = node as? Element {
                    let tag = element.tagNameNormal().lowercased()
                    guard excludedTags.contains(tag) == false else { continue }

                    if element.hasAttr("id") {
                        let id = try element.attr("id")
                        if state.collecting, state.stopFragments.contains(id) {
                            state.stopped = true
                            continue
                        }
                        if state.collecting == false, id == state.requestedFragment {
                            state.collecting = true
                            state.foundStart = true
                        }
                    }

                    if state.collecting, blockTags.contains(tag) {
                        state.output.paragraphBreak()
                    }
                    if state.collecting, tag == "br" {
                        state.output.lineBreak()
                        continue
                    }

                    let children = element.getChildNodes()
                    guard children.isEmpty || depth < EPUBStructureBudget.maximumNestingDepth else {
                        throw EPUBResourceError.tooComplex
                    }
                    events.append(.exit(element))
                    for child in children.reversed() {
                        events.append(.enter(child, depth: depth + 1))
                    }
                } else if state.collecting, let text = node as? TextNode {
                    state.output.append(text.getWholeText())
                }

            case let .exit(element):
                let tag = element.tagNameNormal().lowercased()
                if state.collecting, state.stopped == false, blockTags.contains(tag) {
                    state.output.paragraphBreak()
                }
            }
        }
    }

    private static func visitPageIteratively(_ root: Node, state: inout PageTraversalState) throws {
        var events: [TraversalEvent] = [.enter(root, depth: 1)]

        while let event = events.popLast() {
            if state.stopped || state.output.hasMore { break }
            switch event {
            case let .enter(node, depth):
                guard state.visitedNodes < EPUBStructureBudget.maximumXHTMLNodes else {
                    throw EPUBResourceError.tooComplex
                }
                state.visitedNodes += 1

                if let element = node as? Element {
                    let tag = element.tagNameNormal().lowercased()
                    guard excludedTags.contains(tag) == false else { continue }

                    if element.hasAttr("id") {
                        let id = try element.attr("id")
                        if state.collecting, state.stopFragments.contains(id) {
                            state.stopped = true
                            continue
                        }
                        if state.collecting == false, id == state.requestedFragment {
                            state.collecting = true
                            state.foundStart = true
                        }
                    }

                    if state.collecting, blockTags.contains(tag) {
                        try state.output.paragraphBreak()
                    }
                    if state.collecting, tag == "br" {
                        try state.output.lineBreak()
                        continue
                    }

                    let children = element.getChildNodes()
                    guard children.isEmpty || depth < EPUBStructureBudget.maximumNestingDepth else {
                        throw EPUBResourceError.tooComplex
                    }
                    events.append(.exit(element))
                    for child in children.reversed() {
                        events.append(.enter(child, depth: depth + 1))
                    }
                } else if state.collecting, let text = node as? TextNode {
                    try state.output.append(text.getWholeText())
                }

            case let .exit(element):
                let tag = element.tagNameNormal().lowercased()
                if state.collecting, state.stopped == false, blockTags.contains(tag) {
                    try state.output.paragraphBreak()
                }
            }
        }
    }

    private enum TraversalEvent {
        case enter(Node, depth: Int)
        case exit(Element)
    }

    private struct TraversalState {
        let requestedFragment: String?
        let stopFragments: Set<String>
        var collecting: Bool
        var foundStart: Bool
        var stopped = false
        var output = TextAccumulator()

        init(requestedFragment: String?, stopFragments: Set<String>) {
            self.requestedFragment = requestedFragment
            self.stopFragments = stopFragments
            collecting = requestedFragment == nil
            foundStart = requestedFragment == nil
        }
    }

    private struct PageTraversalState {
        let requestedFragment: String?
        let stopFragments: Set<String>
        var collecting: Bool
        var foundStart: Bool
        var stopped = false
        var visitedNodes = 0
        var output: PageTextAccumulator

        init(
            requestedFragment: String?,
            stopFragments: Set<String>,
            offset: Int,
            maximumGraphemes: Int,
            maximumUTF8Bytes: Int
        ) {
            self.requestedFragment = requestedFragment
            self.stopFragments = stopFragments
            collecting = requestedFragment == nil
            foundStart = requestedFragment == nil
            output = PageTextAccumulator(
                offset: offset,
                maximumGraphemes: maximumGraphemes,
                maximumUTF8Bytes: maximumUTF8Bytes
            )
        }
    }

    private struct PageTextAccumulator {
        private enum PendingSeparator: Int {
            case none
            case space
            case line
            case paragraph
        }

        let offset: Int
        let maximumGraphemes: Int
        let maximumUTF8Bytes: Int
        private(set) var seenGraphemes = 0
        private(set) var returnedGraphemes = 0
        private(set) var hasMore = false
        private(set) var inspectedSourceGraphemes = 0
        private(set) var content = ""
        private var contentUTF8Bytes = 0
        private var pendingSeparator = PendingSeparator.none
        private var emittedVisibleContent = false

        init(offset: Int, maximumGraphemes: Int, maximumUTF8Bytes: Int) {
            self.offset = offset
            self.maximumGraphemes = maximumGraphemes
            self.maximumUTF8Bytes = maximumUTF8Bytes
        }

        mutating func append(_ raw: String) throws {
            for character in raw {
                if hasMore { return }
                inspectedSourceGraphemes += 1
                if character.isWhitespace {
                    if emittedVisibleContent { if pendingSeparator.rawValue < PendingSeparator.space.rawValue { pendingSeparator = .space } }
                    continue
                }
                try flushPendingSeparator()
                if hasMore { return }
                try emit(character)
                emittedVisibleContent = true
            }
        }

        mutating func lineBreak() throws {
            guard emittedVisibleContent else { return }
            if pendingSeparator.rawValue < PendingSeparator.line.rawValue { pendingSeparator = .line }
        }

        mutating func paragraphBreak() throws {
            guard emittedVisibleContent else { return }
            pendingSeparator = .paragraph
        }

        private mutating func flushPendingSeparator() throws {
            let separator = pendingSeparator
            pendingSeparator = .none
            switch separator {
            case .none:
                return
            case .space:
                try emit(" ")
            case .line:
                try emit("\n")
            case .paragraph:
                try emit("\n")
                if hasMore == false { try emit("\n") }
            }
        }

        private mutating func emit(_ character: Character) throws {
            if hasMore { return }
            if seenGraphemes < offset {
                seenGraphemes += 1
                return
            }

            let bytes = String(character).utf8.count
            if returnedGraphemes >= maximumGraphemes || contentUTF8Bytes > maximumUTF8Bytes - bytes {
                guard returnedGraphemes > 0 else { throw EPUBResourceError.tooComplex }
                hasMore = true
                return
            }
            content.append(character)
            contentUTF8Bytes += bytes
            returnedGraphemes += 1
            seenGraphemes += 1
        }
    }

    private struct TextAccumulator {
        private var storage = ""
        private var pendingSpace = false

        var value: String {
            storage.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func append(_ raw: String) {
            for character in raw {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace,
                   storage.isEmpty == false,
                   storage.last?.isWhitespace == false {
                    storage.append(" ")
                }
                pendingSpace = false
                storage.append(character)
            }
        }

        mutating func lineBreak() {
            pendingSpace = false
            while storage.last == " " { storage.removeLast() }
            if storage.isEmpty == false, storage.hasSuffix("\n") == false {
                storage.append("\n")
            }
        }

        mutating func paragraphBreak() {
            pendingSpace = false
            while storage.last == " " || storage.last == "\n" { storage.removeLast() }
            if storage.isEmpty == false { storage.append("\n\n") }
        }
    }
}
