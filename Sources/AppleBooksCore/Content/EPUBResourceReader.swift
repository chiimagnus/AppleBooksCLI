import Foundation

public enum EPUBResourceError: Error, Equatable, Sendable {
    case invalidByteBudget
    case missingResource
    case unsafeResource
    case resourceTooLarge
    case unreadableResource
    case invalidArchive
    case ambiguousResource
    case tooManyEntries
    case tooComplex
}

protocol EPUBResourceReader: AnyObject {
    func contains(_ path: EPUBPath) throws -> Bool
    func readExactResource(_ path: EPUBPath, maxBytes: Int) throws -> Data
}

enum EPUBStructureBudget {
    static let maximumNestingDepth = 256
    static let maximumManifestItems = 20_000
    static let maximumSpineItems = 20_000
    static let maximumNavigationEntries = 20_000
    static let maximumMetadataListValues = 20_000
    static let maximumEncryptionEntries = 20_000
    static let maximumXHTMLNodes = 20_000
    static let maximumZIPEntries = 20_000
    static let maximumIndexedPathBytes = 32 * 1_024 * 1_024
}

enum EPUBResourceBudget {
    // ponytail: 这些固定上限只用于防止损坏/恶意 EPUB 无界占用内存；若真实合法样本超过上限，应按该资源类型调大或改成流式 parser。
    static let container = 512 * 1024
    static let packageDocument = 4 * 1024 * 1024
    static let encryption = 2 * 1024 * 1024
    static let navigation = 4 * 1024 * 1024
    static let plist = 4 * 1024 * 1024
    static let chapter = 32 * 1024 * 1024
    static let cover = 64 * 1024 * 1024
}
