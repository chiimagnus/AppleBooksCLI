import CryptoKit
import Darwin
import Foundation

private let cursorTokenMagic: [UInt8] = [0x41, 0x42, 0x43, 0x50] // ABCP
private let cursorTokenVersion: UInt8 = 1
private let cursorDigestByteCount = 32
private let cursorMaximumTokenBytes = 4_096
private let cursorMaximumLocatorWords = 8
private let cursorMaximumFingerprintFields = 64
private let cursorMaximumFingerprintStringsPerField = 256
private let cursorMaximumFingerprintStringBytes = 64 * 1_024
private let cursorMaximumFingerprintCanonicalBytes = 1 * 1_024 * 1_024
private let cursorMaximumGenerationComponents = 64
private let cursorMaximumDirectoryRelativeNameBytes = 4_096

package func resolvedCursorPageLimit(_ limit: Int?) throws -> Int {
    let effective = limit ?? 20
    guard (1...100).contains(effective) else {
        throw CursorPaginationError.limitOutOfRange
    }
    return effective
}

package enum CursorFingerprintValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case string(String)
    case strings([String])
}

package struct CursorFingerprintField: Equatable, Sendable {
    package let label: String
    package let value: CursorFingerprintValue

    package init(_ label: String, _ value: CursorFingerprintValue) {
        self.label = label
        self.value = value
    }
}

package struct CursorQueryFingerprint: Equatable, Sendable {
    fileprivate let digest: CursorDigest

    package static func make(kind: String, fields: [CursorFingerprintField]) throws -> Self {
        guard isCursorLabel(kind), fields.count <= cursorMaximumFingerprintFields else {
            throw CursorPaginationError.internalContractFailure
        }
        let sorted = fields.sorted { $0.label < $1.label }
        for index in sorted.indices {
            guard isCursorLabel(sorted[index].label),
                  index == sorted.startIndex || sorted[index - 1].label != sorted[index].label else {
                throw CursorPaginationError.internalContractFailure
            }
        }

        var data = Data("applebookscli.cursor.query.v1".utf8)
        appendLengthPrefixed(Data(kind.utf8), to: &data)
        appendUInt16(UInt16(sorted.count), to: &data)
        for field in sorted {
            appendLengthPrefixed(Data(field.label.utf8), to: &data)
            try appendFingerprintValue(field.value, to: &data)
            guard data.count <= cursorMaximumFingerprintCanonicalBytes else {
                throw CursorPaginationError.internalContractFailure
            }
        }
        return Self(digest: CursorDigest.hash(data))
    }
}

package struct CursorLocator: Equatable, Sendable {
    package let words: [UInt64]

    package init(words: [UInt64]) throws {
        guard words.isEmpty == false, words.count <= cursorMaximumLocatorWords else {
            throw CursorPaginationError.internalContractFailure
        }
        self.words = words
    }

    package static func rowID(_ value: Int64) throws -> Self {
        try Self(words: [UInt64(bitPattern: value)])
    }
}

package struct CursorGeneration: Equatable, Sendable {
    fileprivate let digest: CursorDigest

    package static func compose(_ components: [CursorGenerationComponent]) throws -> Self {
        guard components.isEmpty == false,
              components.count <= cursorMaximumGenerationComponents else {
            throw CursorPaginationError.internalContractFailure
        }
        let sorted = components.sorted { $0.label < $1.label }
        for index in sorted.indices {
            guard isCursorLabel(sorted[index].label),
                  index == sorted.startIndex || sorted[index - 1].label != sorted[index].label else {
                throw CursorPaginationError.internalContractFailure
            }
        }

        var data = Data("applebookscli.cursor.generation.v1".utf8)
        appendUInt16(UInt16(sorted.count), to: &data)
        for component in sorted {
            appendLengthPrefixed(Data(component.label.utf8), to: &data)
            data.append(contentsOf: component.digest.bytes)
        }
        return Self(digest: CursorDigest.hash(data))
    }
}

package struct CursorGenerationComponent: Equatable, Sendable {
    fileprivate let label: String
    fileprivate let digest: CursorDigest

    package static func synthetic(label: String, value: String) throws -> Self {
        guard isCursorLabel(label), value.utf8.count <= cursorMaximumFingerprintStringBytes else {
            throw CursorPaginationError.internalContractFailure
        }
        var data = Data("applebookscli.cursor.component.synthetic.v1".utf8)
        appendLengthPrefixed(Data(value.utf8), to: &data)
        return Self(label: label, digest: CursorDigest.hash(data))
    }

    package static func regularFile(label: String, url: URL, optional: Bool = false) throws -> Self {
        guard isCursorLabel(label) else { throw CursorPaginationError.internalContractFailure }
        let metadata = try CursorFileMetadata.read(url: url, expected: .regularFile, missingAllowed: optional)
        var data = Data("applebookscli.cursor.component.file.v1".utf8)
        if let metadata {
            data.append(1)
            metadata.append(to: &data)
        } else {
            data.append(0)
        }
        return Self(label: label, digest: CursorDigest.hash(data))
    }

    package static func sqlite(label: String, databaseURL: URL) throws -> Self {
        guard isCursorLabel(label) else { throw CursorPaginationError.internalContractFailure }
        let main = try CursorFileMetadata.read(url: databaseURL, expected: .regularFile, missingAllowed: false)!
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let wal = try CursorFileMetadata.read(url: walURL, expected: .regularFile, missingAllowed: true)

        var data = Data("applebookscli.cursor.component.sqlite.v1".utf8)
        main.append(to: &data)
        if let wal {
            data.append(1)
            wal.append(to: &data)
        } else {
            data.append(0)
        }
        return Self(label: label, digest: CursorDigest.hash(data))
    }
}

package struct CursorDirectoryGenerationBuilder {
    private let label: String
    private let rootURL: URL
    private let rootMetadata: CursorFileMetadata
    private var accumulator = [UInt8](repeating: 0, count: cursorDigestByteCount)
    private var candidateCount: UInt64 = 0

    package init(label: String, rootURL: URL) throws {
        guard isCursorLabel(label) else { throw CursorPaginationError.internalContractFailure }
        self.label = label
        self.rootURL = rootURL
        rootMetadata = try CursorFileMetadata.read(url: rootURL, expected: .directory, missingAllowed: false)!
    }

    package mutating func add(relativeName: String, fileURL: URL) throws {
        guard isSafeCursorRelativeName(relativeName) else {
            throw CursorPaginationError.internalContractFailure
        }
        let expectedURL = rootURL.appendingPathComponent(relativeName).standardizedFileURL
        guard fileURL.standardizedFileURL == expectedURL else {
            throw CursorPaginationError.internalContractFailure
        }
        let metadata = try CursorFileMetadata.read(url: expectedURL, expected: .regularFile, missingAllowed: false)!
        try add(relativeName: relativeName, metadata: metadata)
    }

    package mutating func add(relativeName: String, metadata: CursorFileMetadata) throws {
        guard isSafeCursorRelativeName(relativeName) else {
            throw CursorPaginationError.internalContractFailure
        }
        var data = Data("applebookscli.cursor.directory.entry.v1".utf8)
        appendLengthPrefixed(Data(relativeName.utf8), to: &data)
        metadata.append(to: &data)
        addDigestModulo256(CursorDigest.hash(data).bytes, into: &accumulator)
        guard candidateCount < UInt64.max else { throw CursorPaginationError.internalContractFailure }
        candidateCount += 1
    }

    package mutating func finish() throws -> CursorGenerationComponent {
        let currentRoot = try CursorFileMetadata.read(url: rootURL, expected: .directory, missingAllowed: false)!
        guard currentRoot == rootMetadata else { throw CursorPaginationError.staleCursor }
        var data = Data("applebookscli.cursor.component.directory.v1".utf8)
        rootMetadata.append(to: &data)
        appendUInt64(candidateCount, to: &data)
        data.append(contentsOf: accumulator)
        return CursorGenerationComponent(label: label, digest: CursorDigest.hash(data))
    }

    package var retainedCandidateNameCount: Int { 0 }
}

package struct CursorPaginationSession: Sendable {
    package let locator: CursorLocator?
    private let fingerprint: CursorQueryFingerprint
    private let generation: CursorGeneration

    package init(cursor: String?, fingerprint: CursorQueryFingerprint, generation: CursorGeneration) throws {
        self.fingerprint = fingerprint
        self.generation = generation
        if let cursor {
            locator = try CursorTokenCodec.decode(
                cursor,
                expectedFingerprint: fingerprint,
                expectedGeneration: generation
            )
        } else {
            locator = nil
        }
    }

    package func nextCursor(
        after afterGeneration: CursorGeneration,
        hasMore: Bool,
        locator nextLocator: CursorLocator?
    ) throws -> String? {
        guard afterGeneration == generation else { throw CursorPaginationError.staleCursor }
        guard hasMore else { return nil }
        guard let nextLocator else { throw CursorPaginationError.internalContractFailure }
        return try CursorTokenCodec.encode(
            locator: nextLocator,
            fingerprint: fingerprint,
            generation: generation
        )
    }
}

package func makeCursorPage<Element>(
    candidates: [Element],
    limit: Int,
    total: Int? = nil,
    session: CursorPaginationSession,
    afterGeneration: CursorGeneration,
    locator: (Element) throws -> CursorLocator
) throws -> CursorPage<Element> {
    guard (1...100).contains(limit), candidates.count <= limit + 1 else {
        throw CursorPaginationError.internalContractFailure
    }
    let hasMore = candidates.count > limit
    let items = Array(candidates.prefix(limit))
    let nextLocator = hasMore ? try items.last.map(locator) : nil
    let nextCursor = try session.nextCursor(
        after: afterGeneration,
        hasMore: hasMore,
        locator: nextLocator
    )
    return CursorPage(items: items, nextCursor: nextCursor, hasMore: hasMore, total: total)
}

package struct CursorFileMetadata: Equatable, Sendable {
    fileprivate enum ExpectedKind {
        case regularFile
        case directory
    }

    package let device: UInt64
    package let inode: UInt64
    package let size: UInt64
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64

    package init(
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }

    fileprivate static func read(
        url: URL,
        expected: ExpectedKind,
        missingAllowed: Bool
    ) throws -> CursorFileMetadata? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if missingAllowed && errno == ENOENT { return nil }
            throw CursorPaginationError.generationUnavailable
        }
        let kind = info.st_mode & S_IFMT
        switch expected {
        case .regularFile:
            guard kind == S_IFREG else { throw CursorPaginationError.generationUnavailable }
        case .directory:
            guard kind == S_IFDIR else { throw CursorPaginationError.generationUnavailable }
        }
        guard info.st_size >= 0 else { throw CursorPaginationError.generationUnavailable }
        return CursorFileMetadata(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    fileprivate func append(to data: inout Data) {
        appendUInt64(device, to: &data)
        appendUInt64(inode, to: &data)
        appendUInt64(size, to: &data)
        appendUInt64(UInt64(bitPattern: modificationSeconds), to: &data)
        appendUInt64(UInt64(bitPattern: modificationNanoseconds), to: &data)
    }
}

private struct CursorDigest: Equatable, Sendable {
    let bytes: [UInt8]

    static func hash(_ data: Data) -> Self {
        Self(bytes: Array(SHA256.hash(data: data)))
    }
}

private enum CursorTokenCodec {
    static func encode(
        locator: CursorLocator,
        fingerprint: CursorQueryFingerprint,
        generation: CursorGeneration
    ) throws -> String {
        var payload = Data(cursorTokenMagic)
        payload.append(cursorTokenVersion)
        payload.append(contentsOf: fingerprint.digest.bytes)
        payload.append(contentsOf: generation.digest.bytes)
        payload.append(UInt8(locator.words.count))
        for word in locator.words {
            appendUInt64(word, to: &payload)
        }
        let token = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard token.utf8.count < cursorMaximumTokenBytes else {
            throw CursorPaginationError.internalContractFailure
        }
        return token
    }

    static func decode(
        _ token: String,
        expectedFingerprint: CursorQueryFingerprint,
        expectedGeneration: CursorGeneration
    ) throws -> CursorLocator {
        let utf8 = token.utf8
        guard utf8.isEmpty == false,
              utf8.count <= cursorMaximumTokenBytes,
              utf8.allSatisfy(isBase64URLByte) else {
            throw CursorPaginationError.invalidCursor
        }

        var encoded = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded) else {
            throw CursorPaginationError.invalidCursor
        }

        let minimumLength = cursorTokenMagic.count + 1 + cursorDigestByteCount * 2 + 1 + 8
        guard payload.count >= minimumLength else { throw CursorPaginationError.invalidCursor }
        var reader = CursorBinaryReader(data: payload)
        guard try reader.readBytes(cursorTokenMagic.count) == cursorTokenMagic,
              try reader.readUInt8() == cursorTokenVersion else {
            throw CursorPaginationError.invalidCursor
        }
        let fingerprint = try reader.readBytes(cursorDigestByteCount)
        let generation = try reader.readBytes(cursorDigestByteCount)
        let wordCount = Int(try reader.readUInt8())
        guard (1...cursorMaximumLocatorWords).contains(wordCount) else {
            throw CursorPaginationError.invalidCursor
        }
        var words: [UInt64] = []
        words.reserveCapacity(wordCount)
        for _ in 0..<wordCount {
            words.append(try reader.readUInt64())
        }
        guard reader.isAtEnd else { throw CursorPaginationError.invalidCursor }
        guard fingerprint == expectedFingerprint.digest.bytes else {
            throw CursorPaginationError.filterMismatch
        }
        guard generation == expectedGeneration.digest.bytes else {
            throw CursorPaginationError.staleCursor
        }
        return try CursorLocator(words: words)
    }
}

private struct CursorBinaryReader {
    let data: Data
    var index = 0

    mutating func readUInt8() throws -> UInt8 {
        let bytes = try readBytes(1)
        return bytes[0]
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index <= data.count - count else {
            throw CursorPaginationError.invalidCursor
        }
        let result = Array(data[index..<(index + count)])
        index += count
        return result
    }

    var isAtEnd: Bool { index == data.count }
}

private func appendFingerprintValue(_ value: CursorFingerprintValue, to data: inout Data) throws {
    switch value {
    case .null:
        data.append(0)
    case let .bool(value):
        data.append(1)
        data.append(value ? 1 : 0)
    case let .signed(value):
        data.append(2)
        appendUInt64(UInt64(bitPattern: value), to: &data)
    case let .unsigned(value):
        data.append(3)
        appendUInt64(value, to: &data)
    case let .string(value):
        data.append(4)
        try appendFingerprintString(value, to: &data)
    case let .strings(values):
        guard values.count <= cursorMaximumFingerprintStringsPerField else {
            throw CursorPaginationError.internalContractFailure
        }
        data.append(5)
        appendUInt16(UInt16(values.count), to: &data)
        for value in values {
            try appendFingerprintString(value, to: &data)
        }
    }
}

private func appendFingerprintString(_ value: String, to data: inout Data) throws {
    let bytes = Data(value.utf8)
    guard bytes.count <= cursorMaximumFingerprintStringBytes,
          data.count <= cursorMaximumFingerprintCanonicalBytes - bytes.count - 4 else {
        throw CursorPaginationError.internalContractFailure
    }
    appendLengthPrefixed(bytes, to: &data)
}

private func appendLengthPrefixed(_ bytes: Data, to data: inout Data) {
    precondition(bytes.count <= Int(UInt32.max))
    appendUInt32(UInt32(bytes.count), to: &data)
    data.append(bytes)
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
}

private func addDigestModulo256(_ value: [UInt8], into accumulator: inout [UInt8]) {
    precondition(value.count == cursorDigestByteCount && accumulator.count == cursorDigestByteCount)
    var carry: UInt16 = 0
    for index in stride(from: cursorDigestByteCount - 1, through: 0, by: -1) {
        let sum = UInt16(accumulator[index]) + UInt16(value[index]) + carry
        accumulator[index] = UInt8(sum & 0xff)
        carry = sum >> 8
    }
}

private func isCursorLabel(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.isEmpty == false && bytes.count <= 128 && bytes.allSatisfy { byte in
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2e || byte == 0x2d || byte == 0x5f
    }
}

private func isBase64URLByte(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    (byte >= 0x30 && byte <= 0x39) ||
    byte == 0x2d || byte == 0x5f
}

private func isSafeCursorRelativeName(_ value: String) -> Bool {
    let bytes = value.utf8
    guard bytes.isEmpty == false,
          bytes.count <= cursorMaximumDirectoryRelativeNameBytes,
          bytes.contains(0) == false,
          value.hasPrefix("/") == false else {
        return false
    }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { component in
        component.isEmpty == false && component != "." && component != ".."
    }
}
