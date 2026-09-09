import Foundation

package enum AppleBooksDependency: String, Equatable, Sendable {
    case libraryRead
    case annotationsRead
    case configuration
    case collectionWrite
    case annotationWrite
    case libraryBackup
    case pdfWorker
}

package struct AppleBooksDependencies: OptionSet, Sendable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let libraryRead = Self(rawValue: 1 << 0)
    package static let annotationsRead = Self(rawValue: 1 << 1)
    package static let configuration = Self(rawValue: 1 << 2)
    package static let collectionWrite = Self(rawValue: 1 << 3)
    package static let annotationWrite = Self(rawValue: 1 << 4)
    package static let libraryBackup = Self(rawValue: 1 << 5)
    package static let pdfWorker = Self(rawValue: 1 << 6)

    package static let full: Self = [
        .libraryRead,
        .annotationsRead,
        .configuration,
        .collectionWrite,
        .annotationWrite,
        .libraryBackup,
        .pdfWorker,
    ]

    package var needsLibraryDatabase: Bool {
        contains(.libraryRead) || contains(.collectionWrite) || contains(.libraryBackup) || contains(.pdfWorker)
    }

    package var needsAnnotationsDatabase: Bool {
        contains(.annotationsRead) || contains(.annotationWrite)
    }
}

package enum AppleBooksDependencyError: Error, Equatable, Sendable {
    case unavailable(AppleBooksDependency)
    case invalidComposition
}
