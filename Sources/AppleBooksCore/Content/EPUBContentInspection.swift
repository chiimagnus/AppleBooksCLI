import Foundation

package struct SemanticEPUBMetadataInspection: Equatable, Sendable {
    package let bookLocalPK: Int64
    package let bookAssetID: String?
    package let source: EPUBContentSource
    package let metadata: EPUBMetadata
    package let databaseFallback: BookContentMetadataFallback
}

public struct EPUBCoverInspection: Equatable, Sendable {
    public let bookLocalPK: Int64
    public let bookAssetID: String?
    public let source: EPUBContentSource
    public let cover: EPUBCover
}

enum EPUBContentInspector {
    static func metadata(
        target: BookResourceTarget,
        databaseFallback: BookContentMetadataFallback,
        configuration: AppleBooksConfiguration
    ) throws -> SemanticEPUBMetadataInspection {
        let selected = try EPUBSourceResolver.resolve(for: target, configuration: configuration).requireReader()
        let content = try BookContent(reader: selected.reader)
        return SemanticEPUBMetadataInspection(
            bookLocalPK: target.localPK,
            bookAssetID: target.assetID,
            source: selected.source,
            metadata: try content.metadata(),
            databaseFallback: databaseFallback
        )
    }

    static func cover(target: BookResourceTarget, configuration: AppleBooksConfiguration) throws -> EPUBCoverInspection? {
        let selected = try EPUBSourceResolver.resolve(for: target, configuration: configuration).requireReader()
        let content = try BookContent(reader: selected.reader)
        guard let cover = try content.cover() else { return nil }
        return EPUBCoverInspection(
            bookLocalPK: target.localPK,
            bookAssetID: target.assetID,
            source: selected.source,
            cover: cover
        )
    }
}
