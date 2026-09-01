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

    func databases() throws -> DiscoveredAppleBooksDatabases {
        try databaseDiscovery.discover(
            libraryOverride: global.libraryDB.map(URL.init(fileURLWithPath:)),
            annotationsOverride: global.annotationsDB.map(URL.init(fileURLWithPath:))
        )
    }

    func makeAppleBooks(
        pdfWorkerURL: URL? = nil,
        pdfWorkerTimeout: TimeInterval? = nil
    ) throws -> AppleBooks {
        let databases = try databases()
        return try AppleBooks(
            libraryDB: databases.libraryDB,
            annotationsDB: databases.annotationsDB,
            configurationFile: configurationFile,
            pdfWorkerURL: pdfWorkerURL,
            pdfWorkerTimeout: pdfWorkerTimeout
        )
    }
}
