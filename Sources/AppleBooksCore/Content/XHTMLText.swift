import Foundation
import SwiftSoup

public enum XHTMLTextError: Error, Equatable, Sendable {
    case invalidDocument
    case fragmentNotFound
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
        try visit(body, state: &state)
        if state.requestedFragment != nil, state.foundStart == false {
            throw XHTMLTextError.fragmentNotFound
        }
        return state.output.value
    }

    private static func visit(_ node: Node, state: inout TraversalState) throws {
        guard state.stopped == false else { return }
        if let element = node as? Element {
            let tag = element.tagNameNormal().lowercased()
            guard excludedTags.contains(tag) == false else { return }

            if element.hasAttr("id") {
                let id = try element.attr("id")
                if state.collecting, state.stopFragments.contains(id) {
                    state.stopped = true
                    return
                }
                if state.collecting == false, id == state.requestedFragment {
                    state.collecting = true
                    state.foundStart = true
                }
            }

            if state.collecting, blockTags.contains(tag) { state.output.paragraphBreak() }
            if state.collecting, tag == "br" {
                state.output.lineBreak()
                return
            }
            for child in element.getChildNodes() {
                try visit(child, state: &state)
                if state.stopped { break }
            }
            if state.collecting, state.stopped == false, blockTags.contains(tag) {
                state.output.paragraphBreak()
            }
            return
        }

        if state.collecting, let text = node as? TextNode {
            state.output.append(text.getWholeText())
        }
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
