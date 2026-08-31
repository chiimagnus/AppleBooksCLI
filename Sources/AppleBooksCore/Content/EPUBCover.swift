import Foundation

public enum EPUBCoverSource: Equatable, Sendable {
    case manifestProperty
    case metadataID
    case commonNameFallback
}

public struct EPUBCover: Equatable, Sendable {
    public let data: Data
    public let declaredMediaType: String?
    public let detectedMediaType: String?
    public let source: EPUBCoverSource

    public var mediaType: String? {
        detectedMediaType ?? declaredMediaType
    }

    public init(data: Data, declaredMediaType: String?, detectedMediaType: String?, source: EPUBCoverSource) {
        self.data = data
        self.declaredMediaType = declaredMediaType
        self.detectedMediaType = detectedMediaType
        self.source = source
    }
}

public extension BookContent {
    func cover() throws -> EPUBCover? {
        let propertyItems = package.manifest.values
            .filter { $0.properties.contains("cover-image") }
            .sorted { $0.id < $1.id }
        for item in propertyItems {
            if let cover = readCover(item: item, source: .manifestProperty) { return cover }
        }

        if let metadata = try? metadata(),
           let coverItemID = metadata.coverItemID,
           let item = package.manifest[coverItemID],
           let cover = readCover(item: item, source: .metadataID) {
            return cover
        }

        let roots = ["", "OEBPS", "OPS"]
        let folders = ["", "images", "Images", "Pictures"]
        let names = ["cover", "thumbnail", "frontcover"]
        let extensions = ["jpg", "jpeg", "png", "gif"]
        for root in roots {
            for folder in folders {
                for name in names {
                    for fileExtension in extensions {
                        let components = [root, folder, "\(name).\(fileExtension)"].filter { $0.isEmpty == false }
                        let reference = components.joined(separator: "/")
                        guard let path = try? EPUBPath.resolve(root: package.root, reference: reference),
                              let data = readCoverData(path) else {
                            continue
                        }
                        return EPUBCover(
                            data: data,
                            declaredMediaType: nil,
                            detectedMediaType: detectImageMediaType(data),
                            source: .commonNameFallback
                        )
                    }
                }
            }
        }
        return nil
    }

    private func readCover(item: EPUBManifestItem, source: EPUBCoverSource) -> EPUBCover? {
        guard let data = readCoverData(item.path) else { return nil }
        return EPUBCover(
            data: data,
            declaredMediaType: item.mediaType,
            detectedMediaType: detectImageMediaType(data),
            source: source
        )
    }

    private func readCoverData(_ path: EPUBPath) -> Data? {
        guard BookContentAvailability.inspect(path.url) == .available else { return nil }
        return try? DirectoryEPUBPackage.readAvailableFile(path)
    }
}

private func detectImageMediaType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(8))
    if bytes.count >= 3, bytes[0...2].elementsEqual([0xFF, 0xD8, 0xFF]) {
        return "image/jpeg"
    }
    if bytes.count >= 8, bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return "image/png"
    }
    if data.count >= 6,
       let signature = String(data: data.prefix(6), encoding: .ascii),
       signature == "GIF87a" || signature == "GIF89a" {
        return "image/gif"
    }
    return nil
}
