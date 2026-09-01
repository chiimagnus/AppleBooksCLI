import Foundation

enum ExportCoverMedia {
    static func resolve(_ cover: EPUBCover) throws -> (type: String, extension: String) {
        switch cover.mediaType?.lowercased() {
        case "image/jpeg": ("image/jpeg", "jpg")
        case "image/png": ("image/png", "png")
        case "image/gif": ("image/gif", "gif")
        default: throw ExportFileWriterError.unsupportedCoverMediaType
        }
    }
}
