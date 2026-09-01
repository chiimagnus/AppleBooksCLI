import Foundation
import Testing

@Suite("CapabilityParityTests")
struct CapabilityParityTests {
    @Test
    func requiredMatrixRowsHaveRealImplementationTestAndCLIReachabilityAnchors() throws {
        let root = repositoryRoot()
        let rows = try matrixRows(at: root.appendingPathComponent("docs/capability-matrix.md"))
        let duplicateMatrixKeys = duplicates(rows.map(\.capability))
        #expect(duplicateMatrixKeys.isEmpty, "duplicate capability names: \(duplicateMatrixKeys.sorted())")

        let coreVerified = Set(rows.filter(\.isCoreVerified).map(\.capability))
        let cliVerified = Set(rows.filter(\.isCLIVerified).map(\.capability))
        let required = Set(rows.filter(\.isRequiredCategory).map(\.capability))
        #expect(coreVerified.isSubset(of: required))
        #expect(coreVerified.isEmpty == false)
        #expect(cliVerified == required, "required capability missing CLI verification: \(required.subtracting(cliVerified).sorted())")

        let fixtureURL = root.appendingPathComponent("Tests/Fixtures/Parity/capability-anchors.json")
        let data = try Data(contentsOf: fixtureURL)
        let rawKeys = try topLevelObjectKeys(in: data)
        let duplicateJSONKeys = duplicates(rawKeys)
        #expect(duplicateJSONKeys.isEmpty, "duplicate anchor keys: \(duplicateJSONKeys.sorted())")

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let anchorKeys = Set(object.keys)
        #expect(
            anchorKeys == required,
            "required anchor mismatch; missing=\(required.subtracting(anchorKeys).sorted()) extra=\(anchorKeys.subtracting(required).sorted())"
        )

        for capability in anchorKeys.sorted() {
            let value = try #require(object[capability] as? [String: Any])
            #expect(
                Set(value.keys) == ["implementationPaths", "testPaths", "cliHelpArgs"],
                "\(capability) anchor contains unsupported fields: \(value.keys.sorted())"
            )
            let implementationPaths = try stringArray(value["implementationPaths"], capability: capability)
            let testPaths = try stringArray(value["testPaths"], capability: capability)
            let cliHelpArgs = try stringMatrix(value["cliHelpArgs"], capability: capability)
            #expect(implementationPaths.isEmpty == false, "\(capability) has no implementation path")
            #expect(testPaths.isEmpty == false, "\(capability) has no executable test path")
            #expect(cliHelpArgs.isEmpty == false, "\(capability) has no CLI help reachability")
            #expect(Set(implementationPaths).count == implementationPaths.count)
            #expect(Set(testPaths).count == testPaths.count)
            #expect(Set(cliHelpArgs.map { $0.joined(separator: "\u{1F}") }).count == cliHelpArgs.count)

            let row = try #require(rows.first { $0.capability == capability })
            for path in implementationPaths {
                let file = try anchoredFile(path, under: root)
                if row.isCoreVerified {
                    #expect(path.hasPrefix("Sources/AppleBooksCore/") || path.hasPrefix("Sources/AppleBooksPDFWorker/"))
                    #expect(path.hasPrefix("Sources/AppleBooksCLI/") == false, "P6 core anchor must remain core-owned")
                } else {
                    #expect(row.isCLIVerified)
                    #expect(path.hasPrefix("Sources/AppleBooksCLI/"), "P7-only capability must point at its real CLI owner")
                }
                #expect(file.pathExtension == "swift")
                #expect(try Data(contentsOf: file).isEmpty == false)
            }
            for path in testPaths {
                let file = try anchoredFile(path, under: root)
                if row.isCoreVerified {
                    #expect(path.hasPrefix("Tests/AppleBooksCoreTests/"))
                } else {
                    #expect(path.hasPrefix("Tests/AppleBooksCLITests/"), "P7-only capability must point at an executable CLI test")
                }
                #expect(file.pathExtension == "swift")
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    text.contains("@Test") || text.contains("XCTestCase"),
                    "\(capability) test anchor is not an executable test source: \(path)"
                )
            }
            for mapping in cliHelpArgs {
                #expect(mapping.isEmpty == false, "\(capability) has an empty CLI help mapping")
                #expect(mapping.allSatisfy { $0.isEmpty == false })
                #expect(mapping.contains("--help") == false, "--help is appended by the executable reachability gate")
                var sawFlag = false
                for argument in mapping {
                    if argument.hasPrefix("--") {
                        sawFlag = true
                    } else {
                        #expect(sawFlag == false, "command-path tokens must precede expected help flags: \(mapping)")
                    }
                }
            }
        }
    }

    @Test
    func p6RenderersStayDatabaseFreeAndProductionRuntimeStaysSwiftOnly() throws {
        let root = repositoryRoot()
        let rendererPaths = [
            "Sources/AppleBooksCore/Export/JSONExporter.swift",
            "Sources/AppleBooksCore/Export/CSVExporter.swift",
            "Sources/AppleBooksCore/Export/MarkdownAnnotationExporter.swift",
            "Sources/AppleBooksCore/Export/HTMLExporter.swift",
        ]
        let forbiddenRendererTokens = [
            "import SQLite3",
            "SQLiteConnection",
            "AppleBooksTable",
            "SELECT ",
            "INSERT ",
            "UPDATE ",
            "DELETE FROM ",
        ]
        for path in rendererPaths {
            let file = try anchoredFile(path, under: root)
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenRendererTokens {
                #expect(text.contains(token) == false, "renderer owns database logic: \(path) token=\(token)")
            }
        }

        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var nonSwiftFiles: [String] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if file.pathExtension != "swift" {
                nonSwiftFiles.append(file.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        #expect(nonSwiftFiles.isEmpty, "non-Swift production runtime files: \(nonSwiftFiles.sorted())")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func matrixRows(at url: URL) throws -> [MatrixRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            guard line.hasPrefix("|") else { return nil }
            let cells = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3,
                  cells[0] != "能力",
                  cells[0] != "宿主包装",
                  cells[0].allSatisfy({ $0 == "-" }) == false else {
                return nil
            }
            return MatrixRow(capability: cells[0], status: cells[1])
        }
    }

    private func stringMatrix(_ raw: Any?, capability: String) throws -> [[String]] {
        guard let values = raw as? [Any] else {
            throw CapabilityParityFixtureError.invalidAnchor(capability)
        }
        return try values.map { try stringArray($0, capability: capability) }
    }

    private func stringArray(_ raw: Any?, capability: String) throws -> [String] {
        guard let values = raw as? [Any] else {
            throw CapabilityParityFixtureError.invalidAnchor(capability)
        }
        let strings = try values.map { value -> String in
            guard let string = value as? String, string.isEmpty == false else {
                throw CapabilityParityFixtureError.invalidAnchor(capability)
            }
            return string
        }
        return strings
    }

    private func anchoredFile(_ path: String, under root: URL) throws -> URL {
        guard path.hasPrefix("/") == false else {
            throw CapabilityParityFixtureError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.contains("..") == false, components.contains(".") == false else {
            throw CapabilityParityFixtureError.unsafePath(path)
        }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path == file.path,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CapabilityParityFixtureError.stalePath(path)
        }
        return file
    }

    private func duplicates(_ values: [String]) -> Set<String> {
        var seen = Set<String>()
        var duplicate = Set<String>()
        for value in values where seen.insert(value).inserted == false {
            duplicate.insert(value)
        }
        return duplicate
    }

    private func topLevelObjectKeys(in data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CapabilityParityFixtureError.invalidJSON
        }
        let characters = Array(text)
        var objectDepth = 0
        var arrayDepth = 0
        var keys: [String] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "{":
                objectDepth += 1
            case "}":
                objectDepth -= 1
            case "[":
                arrayDepth += 1
            case "]":
                arrayDepth -= 1
            case "\"":
                let start = index
                var escaped = false
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == "\"" {
                        break
                    }
                    index += 1
                }
                guard index < characters.count else {
                    throw CapabilityParityFixtureError.invalidJSON
                }
                let end = index
                if objectDepth == 1, arrayDepth == 0 {
                    var lookahead = end + 1
                    while lookahead < characters.count, characters[lookahead].isWhitespace {
                        lookahead += 1
                    }
                    if lookahead < characters.count, characters[lookahead] == ":" {
                        let literal = String(characters[start...end])
                        guard let literalData = literal.data(using: .utf8) else {
                            throw CapabilityParityFixtureError.invalidJSON
                        }
                        keys.append(try JSONDecoder().decode(String.self, from: literalData))
                    }
                }
            default:
                break
            }
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw CapabilityParityFixtureError.invalidJSON
            }
            index += 1
        }
        guard objectDepth == 0, arrayDepth == 0 else {
            throw CapabilityParityFixtureError.invalidJSON
        }
        return keys
    }
}

private struct MatrixRow {
    let capability: String
    let status: String

    var isRequiredCategory: Bool {
        status.hasPrefix("必须复刻") ||
            status.hasPrefix("宿主能力翻译") ||
            status.hasPrefix("本地保留")
    }

    var isCoreVerified: Bool {
        isRequiredCategory && (status.contains("core已验收") || status.contains("已固化"))
    }

    var isCLIVerified: Bool {
        isRequiredCategory && status.contains("CLI已验收")
    }
}

private enum CapabilityParityFixtureError: Error {
    case invalidJSON
    case invalidAnchor(String)
    case unsafePath(String)
    case stalePath(String)
}
