#!/usr/bin/env swift

import Foundation

private enum ScanError: Error {
    case invalidArguments
    case processFailed
    case malformedGitOutput
    case requiredPrivateSourceUnavailable
    case unsafeTrackedPath
    case unreadableWorkingOwner
    case selfTestFailed
}

private struct Finding: Hashable {
    let scope: String
    let category: String
    let locator: String
}

private struct PrivateToken: Hashable {
    let bytes: Data
    let category: String
}

private struct GitObject {
    let oid: String
    let type: String
    let size: Int
}

private let fileManager = FileManager.default
private let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")
private let oldOwnerRelativePath = ["skills", "notion-workspace", "tools", "apple-books"].joined(separator: "/")
private let genericUsersPrefix = "/" + "Users" + "/"
private let oldExportPrefix = ["AppleBooks", "Notes", "Export"].joined(separator: "-")

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func runProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL? = nil,
    stdin: Data? = nil
) throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    let inputPipe: Pipe?
    if stdin != nil {
        let pipe = Pipe()
        process.standardInput = pipe
        inputPipe = pipe
    } else {
        process.standardInput = FileHandle.nullDevice
        inputPipe = nil
    }

    do {
        try process.run()
    } catch {
        throw ScanError.processFailed
    }
    if let stdin, let inputPipe {
        inputPipe.fileHandleForWriting.write(stdin)
        try? inputPipe.fileHandleForWriting.close()
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw ScanError.processFailed
    }
    return data
}

private func git(_ arguments: [String], repo: URL, stdin: Data? = nil) throws -> Data {
    try runProcess(
        executable: gitExecutable,
        arguments: ["-C", repo.path] + arguments,
        currentDirectory: repo,
        stdin: stdin
    )
}

private func repositoryRoot() throws -> URL {
    let output = try runProcess(
        executable: gitExecutable,
        arguments: ["rev-parse", "--show-toplevel"],
        currentDirectory: URL(fileURLWithPath: fileManager.currentDirectoryPath)
    )
    guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.hasPrefix("/") else {
        throw ScanError.malformedGitOutput
    }
    return URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
}

private func nulSeparatedStrings(_ data: Data) throws -> [String] {
    if data.isEmpty { return [] }
    var result: [String] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0 {
        let piece = data[start..<index]
        guard let value = String(data: piece, encoding: .utf8), value.isEmpty == false else {
            throw ScanError.malformedGitOutput
        }
        result.append(value)
        start = data.index(after: index)
    }
    guard start == data.endIndex else { throw ScanError.malformedGitOutput }
    return result
}

private func revListObjects(repo: URL, pathLimit: String? = nil) throws -> [(oid: String, path: String?)] {
    var arguments = ["rev-list", "--objects", "--all"]
    if let pathLimit {
        arguments += ["--", pathLimit]
    }
    let output = try git(arguments, repo: repo)
    guard let text = String(data: output, encoding: .utf8) else {
        throw ScanError.malformedGitOutput
    }
    return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let oid = fields.first.map(String.init), oid.isEmpty == false else {
            throw ScanError.malformedGitOutput
        }
        return (oid, fields.count == 2 ? String(fields[1]) : nil)
    }
}

private func gitObjectTypes(repo: URL, oids: [String]) throws -> [GitObject] {
    if oids.isEmpty { return [] }
    let input = Data((oids.joined(separator: "\n") + "\n").utf8)
    let output = try git(["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], repo: repo, stdin: input)
    guard let text = String(data: output, encoding: .utf8) else {
        throw ScanError.malformedGitOutput
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count == oids.count else { throw ScanError.malformedGitOutput }
    return try zip(oids, lines).map { expected, line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              String(fields[0]) == expected,
              let size = Int(fields[2]),
              size >= 0 else {
            throw ScanError.malformedGitOutput
        }
        return GitObject(oid: expected, type: String(fields[1]), size: size)
    }
}

private func firstNewline(in data: Data, from start: Int) -> Int? {
    guard start <= data.count else { return nil }
    return data[start...].firstIndex(of: 10)
}

private func gitBlobBatch(repo: URL, objects: [GitObject]) throws -> [(GitObject, Data)] {
    let blobs = objects.filter { $0.type == "blob" }
    if blobs.isEmpty { return [] }
    let input = Data((blobs.map(\.oid).joined(separator: "\n") + "\n").utf8)
    let output = try git(["cat-file", "--batch"], repo: repo, stdin: input)
    var cursor = 0
    var result: [(GitObject, Data)] = []
    result.reserveCapacity(blobs.count)

    for expected in blobs {
        guard let newline = firstNewline(in: output, from: cursor), newline > cursor,
              let header = String(data: output[cursor..<newline], encoding: .utf8) else {
            throw ScanError.malformedGitOutput
        }
        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              String(fields[0]) == expected.oid,
              String(fields[1]) == "blob",
              let size = Int(fields[2]), size == expected.size else {
            throw ScanError.malformedGitOutput
        }
        let bodyStart = newline + 1
        let bodyEnd = bodyStart + size
        guard bodyEnd < output.count, output[bodyEnd] == 10 else {
            throw ScanError.malformedGitOutput
        }
        result.append((expected, output.subdata(in: bodyStart..<bodyEnd)))
        cursor = bodyEnd + 1
    }
    guard cursor == output.count else { throw ScanError.malformedGitOutput }
    return result
}

private func chunks<T>(_ values: [T], size: Int = 256) -> [[T]] {
    guard values.isEmpty == false else { return [] }
    return stride(from: 0, to: values.count, by: size).map {
        Array(values[$0..<min($0 + size, values.count)])
    }
}

private func meaningfulToken(_ value: String?, category: String) -> PrivateToken? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count >= 6 else { return nil }
    return PrivateToken(bytes: Data(trimmed.utf8), category: category)
}

private func tokensFromConfigurationData(_ data: Data, home: URL) -> Set<PrivateToken> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    var tokens = Set<PrivateToken>()
    if let historical = object["historical_assets"] as? [String: Any] {
        for (assetID, rawValue) in historical {
            if let token = meaningfulToken(assetID, category: "historical_asset_identity") { tokens.insert(token) }
            if let entry = rawValue as? [String: Any],
               let token = meaningfulToken(entry["title"] as? String, category: "historical_title") {
                tokens.insert(token)
            }
        }
    }
    if let rawRoot = object["epub_root"] as? String {
        let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path
        } else {
            expanded = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        if let token = meaningfulToken(expanded, category: "private_epub_root") { tokens.insert(token) }
    }
    return tokens
}

private func regexTokens(_ text: String, pattern: String, category: String) -> Set<PrivateToken> {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var tokens = Set<PrivateToken>()
    for match in regex.matches(in: text, range: range) {
        guard let swiftRange = Range(match.range, in: text),
              let token = meaningfulToken(String(text[swiftRange]), category: category) else { continue }
        tokens.insert(token)
    }
    return tokens
}

private func tokensFromPrivateBlob(_ data: Data, home: URL) -> Set<PrivateToken> {
    var tokens = tokensFromConfigurationData(data, home: home)
    let text = String(decoding: data, as: UTF8.self)
    tokens.formUnion(regexTokens(
        text,
        pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#,
        category: "annotation_uuid"
    ))
    tokens.formUnion(regexTokens(
        text,
        pattern: #"epubcfi\([^\r\n\"']{4,512}\)"#,
        category: "annotation_cfi"
    ))
    let usersPattern = NSRegularExpression.escapedPattern(for: genericUsersPrefix) + #"[^/\s]+/[^\r\n\"']{2,512}"#
    tokens.formUnion(regexTokens(text, pattern: usersPattern, category: "private_absolute_path"))
    return tokens
}

private func loadPrivateTokens() throws -> Set<PrivateToken> {
    let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    let config = home.appendingPathComponent(".config/applebookscli/config.json", isDirectory: false)
    guard let configData = fileManager.contents(atPath: config.path) else {
        throw ScanError.requiredPrivateSourceUnavailable
    }
    var tokens = tokensFromConfigurationData(configData, home: home)
    guard tokens.isEmpty == false else { throw ScanError.requiredPrivateSourceUnavailable }

    let codexRepo = home.appendingPathComponent(".codex", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let historyObjects = try revListObjects(repo: codexRepo, pathLimit: oldOwnerRelativePath)
    guard historyObjects.isEmpty == false else { throw ScanError.requiredPrivateSourceUnavailable }
    let uniqueOIDs = Array(Set(historyObjects.map(\.oid))).sorted()
    var historyBlobCount = 0
    for oidChunk in chunks(uniqueOIDs) {
        let typed = try gitObjectTypes(repo: codexRepo, oids: oidChunk)
        for blobChunk in chunks(typed.filter { $0.type == "blob" }) {
            for (_, data) in try gitBlobBatch(repo: codexRepo, objects: blobChunk) {
                historyBlobCount += 1
                tokens.formUnion(tokensFromPrivateBlob(data, home: home))
            }
        }
    }
    guard historyBlobCount > 0 else { throw ScanError.requiredPrivateSourceUnavailable }

    let workingOwner = codexRepo.appendingPathComponent(oldOwnerRelativePath, isDirectory: true).standardizedFileURL
    if fileManager.fileExists(atPath: workingOwner.path) {
        tokens.formUnion(try tokensFromWorkingOwner(workingOwner, home: home))
    }
    guard tokens.isEmpty == false else { throw ScanError.requiredPrivateSourceUnavailable }
    return tokens
}

private func tokensFromWorkingOwner(_ root: URL, home: URL) throws -> Set<PrivateToken> {
    let canonicalRoot = root.resolvingSymlinksInPath()
    guard canonicalRoot == root else { throw ScanError.unreadableWorkingOwner }
    var tokens = Set<PrivateToken>()
    var stack = [root]
    while let directory = stack.popLast() {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw ScanError.unreadableWorkingOwner
        }
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw ScanError.unreadableWorkingOwner
            }
            if values.isSymbolicLink == true { throw ScanError.unreadableWorkingOwner }
            if values.isDirectory == true {
                stack.append(entry)
            } else if values.isRegularFile == true {
                guard let data = fileManager.contents(atPath: entry.path) else { throw ScanError.unreadableWorkingOwner }
                tokens.formUnion(tokensFromPrivateBlob(data, home: home))
            }
        }
    }
    return tokens
}

private func exactTokenFindings(data: Data, tokens: Set<PrivateToken>, scope: String, locator: String) -> Set<Finding> {
    var findings = Set<Finding>()
    for token in tokens where token.bytes.isEmpty == false {
        if data.range(of: token.bytes) != nil {
            findings.insert(Finding(scope: scope, category: "private_token_\(token.category)", locator: locator))
        }
    }
    return findings
}

private func staticFindings(data: Data, scope: String, locator: String, logMode: Bool) -> Set<Finding> {
    let text = String(decoding: data, as: UTF8.self)
    var findings = Set<Finding>()

    if let regex = try? NSRegularExpression(
        pattern: NSRegularExpression.escapedPattern(for: genericUsersPrefix) + #"([^/\s]+)/"#
    ) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1, let userRange = Range(match.range(at: 1), in: text) else { continue }
            let user = String(text[userRange])
            if logMode && user == "runner" { continue }
            findings.insert(Finding(scope: scope, category: "local_user_absolute_path", locator: locator))
            break
        }
    }

    if text.contains(oldOwnerRelativePath) {
        findings.insert(Finding(scope: scope, category: "legacy_private_owner_path", locator: locator))
    }
    if text.contains(oldExportPrefix + ".json") || text.contains(oldExportPrefix + ".md") {
        findings.insert(Finding(scope: scope, category: "legacy_private_export_artifact", locator: locator))
    }

    let uuidContextPattern = #"(?i)[\"']annotation_uuid[\"']\s*[:=]\s*[\"'][0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[\"']"#
    if text.range(of: uuidContextPattern, options: .regularExpression) != nil {
        findings.insert(Finding(scope: scope, category: "embedded_annotation_uuid", locator: locator))
    }
    let cfiContextPattern = #"(?i)[\"'](?:rawCFI|cfi)[\"']\s*[:=]\s*[\"']epubcfi\([^\r\n\"']{4,512}\)[\"']"#
    if text.range(of: cfiContextPattern, options: .regularExpression) != nil {
        findings.insert(Finding(scope: scope, category: "embedded_annotation_cfi", locator: locator))
    }
    return findings
}

private func scanTracked(repo: URL, tokens: Set<PrivateToken>, includePrivate: Bool) throws -> Set<Finding> {
    let paths = try nulSeparatedStrings(try git(["ls-files", "-z"], repo: repo))
    var findings = Set<Finding>()
    for path in paths {
        let candidate = repo.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard candidate.path == repo.path || candidate.path.hasPrefix(repo.path + "/") else {
            throw ScanError.unsafeTrackedPath
        }
        let data: Data
        var metadata = stat()
        if lstat(candidate.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK {
            data = try git(["show", ":\(path)"], repo: repo)
        } else {
            guard let fileData = fileManager.contents(atPath: candidate.path) else { throw ScanError.unsafeTrackedPath }
            data = fileData
        }
        findings.formUnion(staticFindings(data: data, scope: "tracked", locator: path, logMode: false))
        if includePrivate {
            findings.formUnion(exactTokenFindings(data: data, tokens: tokens, scope: "tracked", locator: path))
        }
    }
    return findings
}

private func scanHistory(repo: URL, tokens: Set<PrivateToken>, includePrivate: Bool) throws -> Set<Finding> {
    let discovered = try revListObjects(repo: repo)
    var pathByOID: [String: String] = [:]
    for item in discovered where pathByOID[item.oid] == nil {
        if let path = item.path { pathByOID[item.oid] = path }
    }
    let uniqueOIDs = Array(Set(discovered.map(\.oid))).sorted()
    var findings = Set<Finding>()
    var checkedBlobCount = 0
    for oidChunk in chunks(uniqueOIDs) {
        let typed = try gitObjectTypes(repo: repo, oids: oidChunk)
        for blobChunk in chunks(typed.filter { $0.type == "blob" }) {
            for (object, data) in try gitBlobBatch(repo: repo, objects: blobChunk) {
                checkedBlobCount += 1
                let path = pathByOID[object.oid]
                let locator = path.map { "\(object.oid.prefix(12)):\($0)" } ?? String(object.oid.prefix(12))
                findings.formUnion(staticFindings(data: data, scope: "history", locator: locator, logMode: false))
                if includePrivate {
                    findings.formUnion(exactTokenFindings(data: data, tokens: tokens, scope: "history", locator: locator))
                }
            }
        }
    }
    guard checkedBlobCount > 0 else { throw ScanError.malformedGitOutput }
    return findings
}

private func report(_ findings: Set<Finding>, mode: String) -> Int32 {
    let ordered = findings.sorted {
        ($0.scope, $0.category, $0.locator) < ($1.scope, $1.category, $1.locator)
    }
    for finding in ordered {
        print("finding scope=\(finding.scope) category=\(finding.category) locator=\(finding.locator)")
    }
    print("privacy scan mode=\(mode) findings=\(ordered.count)")
    return ordered.isEmpty ? 0 : 1
}

private func runSelfTest() throws {
    let secret = "self-test-" + UUID().uuidString.lowercased()
    let token = PrivateToken(bytes: Data(secret.utf8), category: "synthetic")
    let payload = Data(("prefix:" + secret + ":suffix").utf8)
    let findings = exactTokenFindings(data: payload, tokens: [token], scope: "self-test", locator: "synthetic")
    guard findings.count == 1 else { throw ScanError.selfTestFailed }
    let staticPayload = Data((genericUsersPrefix + "example/private/path").utf8)
    guard staticFindings(data: staticPayload, scope: "self-test", locator: "synthetic", logMode: false).isEmpty == false else {
        throw ScanError.selfTestFailed
    }
    let runnerPayload = Data((genericUsersPrefix + "runner/work/repo").utf8)
    guard staticFindings(data: runnerPayload, scope: "self-test", locator: "synthetic", logMode: true).isEmpty else {
        throw ScanError.selfTestFailed
    }
    print("privacy scanner self-test PASS")
}

private func main() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.isEmpty == false else { throw ScanError.invalidArguments }
    let repo = try repositoryRoot()

    switch arguments[0] {
    case "--self-test":
        guard arguments.count == 1 else { throw ScanError.invalidArguments }
        try runSelfTest()
        return 0
    case "--static":
        guard arguments.count == 1 else { throw ScanError.invalidArguments }
        var findings = try scanTracked(repo: repo, tokens: [], includePrivate: false)
        findings.formUnion(try scanHistory(repo: repo, tokens: [], includePrivate: false))
        return report(findings, mode: "static")
    case "--local-private":
        guard arguments.count == 1 else { throw ScanError.invalidArguments }
        let tokens = try loadPrivateTokens()
        var findings = try scanTracked(repo: repo, tokens: tokens, includePrivate: true)
        findings.formUnion(try scanHistory(repo: repo, tokens: tokens, includePrivate: true))
        return report(findings, mode: "local-private")
    case "--scan-log":
        guard arguments.count == 2 else { throw ScanError.invalidArguments }
        let logURL = URL(fileURLWithPath: arguments[1], isDirectory: false).standardizedFileURL
        guard let data = fileManager.contents(atPath: logURL.path) else { throw ScanError.requiredPrivateSourceUnavailable }
        let tokens = try loadPrivateTokens()
        var findings = staticFindings(data: data, scope: "log", locator: "provided-log", logMode: true)
        findings.formUnion(exactTokenFindings(data: data, tokens: tokens, scope: "log", locator: "provided-log"))
        return report(findings, mode: "scan-log")
    default:
        throw ScanError.invalidArguments
    }
}

do {
    exit(try main())
} catch ScanError.invalidArguments {
    fail("usage: check-private-data.swift --self-test | --static | --local-private | --scan-log <file>")
} catch {
    fail("privacy scanner failed closed")
}
