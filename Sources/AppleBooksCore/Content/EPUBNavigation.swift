import Foundation
import SwiftSoup

public enum EPUBNavigationError: Error, Equatable, Sendable {
    case invalidNavigationDocument
}

struct EPUBNavigation {
    let package: DirectoryEPUBPackage

    func chaptersFromNavigation() throws -> [Chapter] {
        let nav = try navChapters()
        return nav.isEmpty ? try ncxChapters() : nav
    }

    func navChapters() throws -> [Chapter] {
        let navItems = package.manifest.values.filter { $0.properties.contains("nav") }
        guard let navItem = navItems.sorted(by: { $0.id < $1.id }).first else { return [] }
        let data = try DirectoryEPUBPackage.readAvailableFile(navItem.path)

        let document: Document
        do {
            document = try SwiftSoup.parse(data, "")
        } catch {
            throw EPUBNavigationError.invalidNavigationDocument
        }

        let tocNav: Element?
        do {
            tocNav = try document.getElementsByTag("nav").first { nav in
                let tokens = try nav.attr("epub:type").split(whereSeparator: \.isWhitespace)
                return tokens.contains { $0 == "toc" }
            }
        } catch {
            throw EPUBNavigationError.invalidNavigationDocument
        }
        guard let tocNav else { return [] }
        guard let rootList = tocNav.children().first(where: { $0.tagName().lowercased() == "ol" }) else {
            return []
        }

        var drafts: [Draft] = []
        var seen = Set<Target>()
        try walk(rootList, depth: 0, navDirectory: navItem.path.directory, drafts: &drafts, seen: &seen)

        var idCounts: [String: Int] = [:]
        for draft in drafts {
            idCounts[draft.preferredID, default: 0] += 1
        }
        return drafts.map { draft in
            Chapter(
                id: idCounts[draft.preferredID, default: 0] > 1 ? String(draft.order) : draft.preferredID,
                title: draft.title,
                href: draft.target.href,
                fragment: draft.target.fragment,
                order: draft.order,
                depth: draft.depth
            )
        }
    }

    private func ncxChapters() throws -> [Chapter] {
        let ncxItems = package.manifest.values.filter { $0.mediaType == "application/x-dtbncx+xml" }
        guard let ncxItem = ncxItems.sorted(by: { $0.id < $1.id }).first else { return [] }
        let data = try DirectoryEPUBPackage.readAvailableFile(ncxItem.path)
        guard let entries = NCXDocument.parse(data), entries.isEmpty == false else { return [] }

        var idCounts: [String: Int] = [:]
        for entry in entries where entry.rawID.isEmpty == false {
            idCounts[entry.rawID, default: 0] += 1
        }

        return try entries.map { entry in
            let path = try EPUBPath.resolve(
                root: package.root,
                reference: entry.src,
                relativeTo: ncxItem.path.directory
            )
            let id = entry.rawID.isEmpty || idCounts[entry.rawID, default: 0] > 1
                ? String(entry.order)
                : entry.rawID
            return Chapter(
                id: id,
                title: entry.title,
                href: path.relativePath,
                fragment: path.fragment ?? "",
                order: entry.order,
                depth: entry.depth
            )
        }
    }

    private func walk(
        _ list: Element,
        depth: Int,
        navDirectory: String,
        drafts: inout [Draft],
        seen: inout Set<Target>
    ) throws {
        for item in list.children() where item.tagName().lowercased() == "li" {
            if let link = item.children().first(where: { $0.tagName().lowercased() == "a" }) {
                let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let href = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty == false, href.isEmpty == false {
                    let path = try EPUBPath.resolve(root: package.root, reference: href, relativeTo: navDirectory)
                    let target = Target(href: path.relativePath, fragment: path.fragment ?? "")
                    if seen.insert(target).inserted {
                        let matchingIDs = package.manifest.values
                            .filter { $0.path.relativePath == path.relativePath }
                            .map(\.id)
                            .sorted()
                        let order = drafts.count + 1
                        drafts.append(Draft(
                            preferredID: matchingIDs.count == 1 ? matchingIDs[0] : String(order),
                            title: title,
                            target: target,
                            order: order,
                            depth: depth
                        ))
                    }
                }
            }

            for childList in item.children() where childList.tagName().lowercased() == "ol" {
                try walk(childList, depth: depth + 1, navDirectory: navDirectory, drafts: &drafts, seen: &seen)
            }
        }
    }

    private struct Target: Hashable {
        let href: String
        let fragment: String
    }

    private struct Draft {
        let preferredID: String
        let title: String
        let target: Target
        let order: Int
        let depth: Int
    }
}

private final class NCXDocument: NSObject, XMLParserDelegate {
    struct Entry {
        let rawID: String
        let title: String
        let src: String
        let order: Int
        let depth: Int
    }

    private struct Pending {
        let rawID: String
        let order: Int
        let depth: Int
        var title = ""
        var src = ""
    }

    private static let namespace = "http://www.daisy.org/z3986/2005/ncx/"
    private var stack: [Pending] = []
    private var entries: [Entry] = []
    private var nextOrder = 0
    private var sawNavMap = false
    private var collectingText = false
    private var textBuffer = ""
    private var incomplete = false

    static func parse(_ data: Data) -> [Entry]? {
        let delegate = NCXDocument()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), delegate.sawNavMap, delegate.incomplete == false else { return nil }
        return delegate.entries.sorted { $0.order < $1.order }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard namespaceURI == Self.namespace else { return }
        switch elementName {
        case "navMap":
            sawNavMap = true
        case "navPoint" where sawNavMap:
            nextOrder += 1
            stack.append(Pending(
                rawID: attributeDict["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                order: nextOrder,
                depth: stack.count
            ))
        case "text" where stack.isEmpty == false:
            collectingText = true
            textBuffer = ""
        case "content" where stack.isEmpty == false:
            stack[stack.count - 1].src = attributeDict["src"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { textBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard namespaceURI == Self.namespace else { return }
        if elementName == "text", collectingText, stack.isEmpty == false {
            stack[stack.count - 1].title = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            collectingText = false
            textBuffer = ""
            return
        }
        guard elementName == "navPoint", let pending = stack.popLast() else { return }
        guard pending.title.isEmpty == false, pending.src.isEmpty == false else {
            incomplete = true
            return
        }
        entries.append(Entry(
            rawID: pending.rawID,
            title: pending.title,
            src: pending.src,
            order: pending.order,
            depth: pending.depth
        ))
    }
}
