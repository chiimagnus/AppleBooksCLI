import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("CLICapabilityReachabilityTests")
struct CLICapabilityReachabilityTests {
    @Test
    func everyImplementedCapabilityHasExecutableHelpReachabilityBeforeDiscovery() throws {
        let root = repositoryRoot()
        let required = try implementedCapabilities(at: root.appendingPathComponent("docs/capability-matrix.md"))
        let anchors = try reachabilityAnchors(at: root.appendingPathComponent("Tests/Fixtures/Parity/capability-anchors.json"))
        try requireCompleteReachability(required: required, anchors: anchors)

        let harness = try ReachabilityHarness(repositoryRoot: root)
        defer { harness.remove() }
        for capability in required.sorted() {
            let anchor = try #require(anchors[capability])
            #expect(anchor.cliHelpArgs.isEmpty == false)
            for mapping in anchor.cliHelpArgs {
                try harness.validateHelp(mapping)
            }
        }
    }

    @Test
    func staleCommandFlagAndMissingRequiredMappingFailClosed() throws {
        let root = repositoryRoot()
        let harness = try ReachabilityHarness(repositoryRoot: root)
        defer { harness.remove() }

        #expect(throws: ReachabilityError.missingCommandToken("definitely-stale")) {
            try harness.validateHelp(["books", "definitely-stale"])
        }
        #expect(throws: ReachabilityError.missingHelpToken("--definitely-stale")) {
            try harness.validateHelp(["books", "list", "--definitely-stale"])
        }

        let present = ReachabilityAnchor(cliHelpArgs: [["books", "list"]])
        #expect(throws: ReachabilityError.anchorMismatch(missing: ["missing"], extra: [])) {
            try requireCompleteReachability(required: ["present", "missing"], anchors: ["present": present])
        }
    }

    @Test
    func executableBehaviorEvidenceReachesCoreQueryAndExportFixtures() throws {
        let fixture = try ReachabilityBehaviorFixture(repositoryRoot: repositoryRoot())
        defer { fixture.remove() }

        let books = try fixture.runJSON(["books", "list", "--all"])
        #expect(books["total"] as? Int == 1)
        let items = try #require(books["items"] as? [[String: Any]])
        #expect(items.first?["assetID"] as? String == "reachability-book")

        let export = try fixture.run(["export", "--format", "json"] + fixture.globalArguments)
        #expect(export.status == CLIProcessExit.success.rawValue)
        #expect(export.stderr.isEmpty)
        let root = try jsonObject(export.stdout)
        let groups = try #require(root["groups"] as? [[String: Any]])
        #expect(groups.count == 1)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ReachabilityAnchor: Decodable, Equatable {
    let cliHelpArgs: [[String]]
}

private func reachabilityAnchors(at url: URL) throws -> [String: ReachabilityAnchor] {
    try JSONDecoder().decode([String: ReachabilityAnchor].self, from: Data(contentsOf: url))
}

private func implementedCapabilities(at url: URL) throws -> Set<String> {
    let text = try String(contentsOf: url, encoding: .utf8)
    let rows = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine -> (String, String)? in
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
        return (cells[0], cells[1])
    }
    return Set(rows.compactMap { capability, status in
        status.hasPrefix("已实现") ? capability : nil
    })
}

private func requireCompleteReachability(
    required: Set<String>,
    anchors: [String: ReachabilityAnchor]
) throws {
    let keys = Set(anchors.keys)
    let missing = required.subtracting(keys).sorted()
    let extra = keys.subtracting(required).sorted()
    guard missing.isEmpty, extra.isEmpty else {
        throw ReachabilityError.anchorMismatch(missing: missing, extra: extra)
    }
}

private final class ReachabilityHarness {
    let root: URL
    let home: URL
    let cwd: URL
    let executable: URL

    init(repositoryRoot: URL) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-reachability-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        executable = repositoryRoot.appendingPathComponent(".build/debug/applebookscli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ReachabilityError.executableUnavailable
        }
    }

    func validateHelp(_ mapping: [String]) throws {
        var command: [String] = []
        var expectedFlags: [String] = []
        var sawFlag = false
        for argument in mapping {
            guard argument.isEmpty == false, argument != "--help" else {
                throw ReachabilityError.malformedMapping
            }
            if argument.hasPrefix("--") {
                sawFlag = true
                expectedFlags.append(argument)
            } else {
                guard sawFlag == false else { throw ReachabilityError.malformedMapping }
                command.append(argument)
            }
        }

        var parentPath: [String] = []
        for component in command {
            let parentHelp = try checkedHelp(parentPath)
            let parentTokens = Set(parentHelp.split(whereSeparator: \.isWhitespace).map(String.init))
            guard parentTokens.contains(component) else {
                throw ReachabilityError.missingCommandToken(component)
            }
            parentPath.append(component)
        }

        let help = try checkedHelp(command)
        let helpTokens = Set(help.split(whereSeparator: \.isWhitespace).map(String.init))
        for flag in expectedFlags where helpTokens.contains(flag) == false {
            throw ReachabilityError.missingHelpToken(flag)
        }
    }

    private func checkedHelp(_ command: [String]) throws -> String {
        let invocation = try run(command + ["--help"])
        guard invocation.status == CLIProcessExit.success.rawValue else {
            throw ReachabilityError.nonzeroExit(invocation.status)
        }
        guard invocation.stderr.isEmpty else { throw ReachabilityError.stderrOutput }
        guard invocation.stdout.isEmpty == false else { throw ReachabilityError.emptyHelp }
        return invocation.stdout
    }

    func run(_ arguments: [String]) throws -> ReachabilityInvocation {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ReachabilityInvocation(
            status: process.terminationStatus,
            stdout: String(decoding: try stdout.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self),
            stderr: String(decoding: try stderr.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ReachabilityInvocation {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ReachabilityBehaviorFixture {
    let harness: ReachabilityHarness
    let root: URL
    let library: URL
    let annotations: URL
    let config: URL

    var globalArguments: [String] {
        [
            "--library-db", library.path,
            "--annotations-db", annotations.path,
            "--config", config.path,
        ]
    }

    init(repositoryRoot: URL) throws {
        harness = try ReachabilityHarness(repositoryRoot: repositoryRoot)
        root = harness.root.appendingPathComponent("behavior", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root.appendingPathComponent("library.sqlite")
        annotations = root.appendingPathComponent("annotations.sqlite")
        config = root.appendingPathComponent("config.json")
        try Self.execute(
            library,
            sql: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZCONTENTTYPE INTEGER
            );
            INSERT INTO ZBKLIBRARYASSET VALUES(1,'reachability-book','Reachability Book',1);
            """
        )
        try Self.execute(
            annotations,
            sql: """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZANNOTATIONNOTE TEXT
            );
            INSERT INTO ZAEANNOTATION VALUES(1,'reachability-book',0,1,'Reachability quote','Reachability note');
            """
        )
        try Data("{}".utf8).write(to: config)
    }

    func run(_ arguments: [String]) throws -> ReachabilityInvocation {
        try harness.run(arguments)
    }

    func runJSON(_ arguments: [String]) throws -> [String: Any] {
        let invocation = try run(arguments + globalArguments + ["--json"])
        #expect(invocation.status == CLIProcessExit.success.rawValue)
        #expect(invocation.stderr.isEmpty)
        return try jsonObject(invocation.stdout)
    }

    func remove() {
        harness.remove()
    }

    private static func execute(_ database: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw ReachabilityError.sqliteFixture
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReachabilityError.sqliteFixture
        }
    }
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw ReachabilityError.invalidJSON
    }
    return value
}

private enum ReachabilityError: Error, Equatable {
    case anchorMismatch(missing: [String], extra: [String])
    case emptyHelp
    case executableUnavailable
    case invalidJSON
    case malformedMapping
    case missingCommandToken(String)
    case missingHelpToken(String)
    case nonzeroExit(Int32)
    case sqliteFixture
    case stderrOutput
}
