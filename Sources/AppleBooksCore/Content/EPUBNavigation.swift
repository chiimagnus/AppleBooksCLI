import Foundation
import SwiftSoup

public enum EPUBNavigationError: Error, Equatable, Sendable {
    case invalidNavigationDocument
}

struct EPUBNavigation {
    let package: DirectoryEPUBPackage

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
