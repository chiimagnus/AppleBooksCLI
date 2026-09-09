import AppleBooksCore
import Foundation

struct CLIContext {
    let global: GlobalOptions
    let databaseDiscovery: DatabaseDiscovery

    init(
        global: GlobalOptions,
        databaseDiscovery: DatabaseDiscovery = DatabaseDiscovery()
    ) {
        self.global = global
        self.databaseDiscovery = databaseDiscovery
    }

    var configurationFile: URL? {
        global.config.map(URL.init(fileURLWithPath:))
    }

    var managesCollectionBooksApplication: Bool {
        global.libraryDB == nil
    }

    var managesAnnotationBooksApplication: Bool {
        global.annotationsDB == nil
    }

    func databases() throws -> DiscoveredAppleBooksDatabases {
        try databaseDiscovery.discover(
            libraryOverride: global.libraryDB.map(URL.init(fileURLWithPath:)),
            annotationsOverride: global.annotationsDB.map(URL.init(fileURLWithPath:))
        )
    }

    func diagnostics(backupRoot: URL = SQLiteBackup.defaultRoot()) -> AppleBooksDiagnosticReport {
        AppleBooksDiagnostics.inspect(
            libraryOverride: global.libraryDB.map(URL.init(fileURLWithPath:)),
            annotationsOverride: global.annotationsDB.map(URL.init(fileURLWithPath:)),
            configurationFile: configurationFile,
            databaseDiscovery: databaseDiscovery,
            backupRoot: backupRoot
        )
    }

    func makeAppleBooks(
        dependencies: AppleBooksDependencies,
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws -> AppleBooks {
        let libraryDB = try dependencies.needsLibraryDatabase
            ? databaseDiscovery.resolve(
                store: .library,
                override: global.libraryDB.map(URL.init(fileURLWithPath:))
            )
            : nil
        let annotationsDB = try dependencies.needsAnnotationsDatabase
            ? databaseDiscovery.resolve(
                store: .annotations,
                override: global.annotationsDB.map(URL.init(fileURLWithPath:))
            )
            : nil
        return try AppleBooks(
            libraryDB: libraryDB,
            annotationsDB: annotationsDB,
            configurationFile: dependencies.contains(.configuration) ? configurationFile : nil,
            dependencies: dependencies,
            manageCollectionBooksApplication: managesCollectionBooksApplication,
            manageAnnotationBooksApplication: managesAnnotationBooksApplication,
            pdfWorkerURL: pdfWorkerURL,
            pdfWorkerTimeout: pdfWorkerTimeout
        )
    }
}
