import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AppleBooksDiagnosticsTests")
struct AppleBooksDiagnosticsTests {
    @Test
    func readyInspectionIsReadOnlyAndDoesNotCreateBackupRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backupRoot = fixture.root.appendingPathComponent("missing/backups", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)

        let report = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: fixture.emptyConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: backupRoot,
            booksApp: fixture.booksApp
        )

        #expect(report.state == .ready)
        #expect(report.libraryDatabaseReady)
        #expect(report.annotationsDatabaseReady)
        #expect(report.readSchemaReady)
        #expect(report.optionalSchemaComplete == false)
        #expect(report.writeSchemaReady)
        #expect(report.configurationReady)
        #expect(report.supplementalRootConfigured == false)
        #expect(report.supplementalRootReady)
        #expect(report.backupLocationReady)
        #expect(report.booksAppRunning == false)
        #expect(report.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
    }

    @Test
    func missingReadCapabilityIsFatalWithoutLeakingSchemaDetails() throws {
        let fixture = try Fixture(librarySQL: Self.librarySQL.replacingOccurrences(of: "  ZPATH TEXT,\n", with: ""))
        defer { fixture.remove() }

        let report = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: fixture.emptyConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )

        #expect(report.state == .fatal)
        #expect(report.libraryDatabaseReady)
        #expect(report.readSchemaReady == false)
        #expect(report.issues.contains(.init(code: .libraryReadSchemaIncompatible, state: .fatal)))
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(encoded.contains("ZPATH") == false)
        #expect(encoded.contains(fixture.root.path) == false)
    }

    @Test
    func writeOnlySchemaGapIsDegradedWhileReadCapabilitiesRemainReady() throws {
        let fixture = try Fixture(librarySQL: Self.librarySQL.replacingOccurrences(of: "  ZHIDDEN INTEGER,\n", with: ""))
        defer { fixture.remove() }

        let report = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: fixture.emptyConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )

        #expect(report.state == .degraded)
        #expect(report.readSchemaReady)
        #expect(report.writeSchemaReady == false)
        #expect(report.issues.contains(.init(code: .libraryWriteSchemaIncompatible, state: .degraded)))
    }

    @Test
    func invalidConfigurationIsFatalAndUnavailableSupplementalRootIsDegraded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid = fixture.root.appendingPathComponent("invalid.json")
        try Data("not-json".utf8).write(to: invalid)

        let invalidReport = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: invalid,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )
        #expect(invalidReport.state == .fatal)
        #expect(invalidReport.configurationReady == false)
        #expect(invalidReport.issues.contains(.init(code: .configurationInvalid, state: .fatal)))

        let missingRoot = fixture.root.appendingPathComponent("missing-epubs", isDirectory: true)
        let supplemental = fixture.root.appendingPathComponent("supplemental.json")
        let escapedPath = missingRoot.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try Data("{\"historical_assets\":{},\"epub_root\":\"\(escapedPath)\"}".utf8).write(to: supplemental)
        let supplementalReport = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: supplemental,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )
        #expect(supplementalReport.state == .degraded)
        #expect(supplementalReport.configurationReady)
        #expect(supplementalReport.supplementalRootConfigured)
        #expect(supplementalReport.supplementalRootReady == false)
        #expect(supplementalReport.issues.contains(.init(code: .supplementalRootUnavailable, state: .degraded)))
    }

    @Test
    func supplementalRootMatchesResolverDirectoryAndSymlinkSemantics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let regularFile = fixture.root.appendingPathComponent("not-a-root")
        try Data().write(to: regularFile)
        let regularConfig = fixture.root.appendingPathComponent("regular-root.json")
        let regularEscaped = regularFile.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try Data("{\"historical_assets\":{},\"epub_root\":\"\(regularEscaped)\"}".utf8).write(to: regularConfig)

        let regularReport = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: regularConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )
        #expect(regularReport.supplementalRootReady == false)
        #expect(regularReport.issues.contains(.init(code: .supplementalRootUnavailable, state: .degraded)))

        let realDirectory = fixture.root.appendingPathComponent("real-epubs", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let symlink = fixture.root.appendingPathComponent("linked-epubs", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: realDirectory.path)
        let symlinkConfig = fixture.root.appendingPathComponent("symlink-root.json")
        let symlinkEscaped = symlink.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try Data("{\"historical_assets\":{},\"epub_root\":\"\(symlinkEscaped)\"}".utf8).write(to: symlinkConfig)

        let symlinkReport = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: symlinkConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            booksApp: fixture.booksApp
        )
        #expect(symlinkReport.supplementalRootReady)
        #expect(symlinkReport.issues.contains(where: { $0.code == .supplementalRootUnavailable }) == false)
    }

    @Test
    func backupLocationProbeNeverCreatesAndRejectsExistingRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backupFile = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: backupFile)

        let report = AppleBooksDiagnostics.inspect(
            libraryOverride: fixture.library,
            annotationsOverride: fixture.annotations,
            configurationFile: fixture.emptyConfig,
            databaseDiscovery: fixture.discovery,
            backupRoot: backupFile,
            booksApp: fixture.booksApp
        )

        #expect(report.state == .degraded)
        #expect(report.backupLocationReady == false)
        #expect(report.issues.contains(.init(code: .backupLocationUnavailable, state: .degraded)))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: backupFile.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue == false)
    }

    @Test
    func databaseProbeFailuresUseLogicalCodesOnly() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths(
            libraryDirectory: root.appendingPathComponent("library", isDirectory: true),
            annotationsDirectory: root.appendingPathComponent("annotations", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.annotationsDirectory, withIntermediateDirectories: true)
        try Data().write(to: paths.libraryDirectory.appendingPathComponent("BKLibrary-a.sqlite"))
        try Data().write(to: paths.libraryDirectory.appendingPathComponent("BKLibrary-b.sqlite"))

        let report = AppleBooksDiagnostics.inspect(
            libraryOverride: nil,
            annotationsOverride: nil,
            configurationFile: root.appendingPathComponent("absent-config.json"),
            databaseDiscovery: DatabaseDiscovery(paths: paths),
            backupRoot: root.appendingPathComponent("backups", isDirectory: true),
            booksApp: BooksAppController(
                isRunning: { false },
                terminate: { Issue.record("diagnostics must not terminate Books"); return false },
                launch: { Issue.record("diagnostics must not launch Books") }
            )
        )

        #expect(report.state == .fatal)
        #expect(report.issues.contains(.init(code: .libraryDatabaseAmbiguous, state: .fatal)))
        #expect(report.issues.contains(.init(code: .annotationsDatabaseMissing, state: .fatal)))
        #expect(report.optionalSchemaComplete == false)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(encoded.contains("BKLibrary-a.sqlite") == false)
        #expect(encoded.contains(root.path) == false)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let emptyConfig: URL
        let discovery: DatabaseDiscovery
        let booksApp: BooksAppController

        init(librarySQL: String = AppleBooksDiagnosticsTests.librarySQL) throws {
            root = AppleBooksDiagnosticsTests().temporaryDirectory()
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            try AppleBooksDiagnosticsTests().createDatabase(library, sql: librarySQL)
            try AppleBooksDiagnosticsTests().createDatabase(annotations, sql: AppleBooksDiagnosticsTests.annotationSQL)
            emptyConfig = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: emptyConfig)
            discovery = DatabaseDiscovery(
                paths: AppleBooksDatabasePaths(
                    libraryDirectory: root.appendingPathComponent("unused-library", isDirectory: true),
                    annotationsDirectory: root.appendingPathComponent("unused-annotations", isDirectory: true)
                )
            )
            booksApp = BooksAppController(
                isRunning: { false },
                terminate: { Issue.record("diagnostics must not terminate Books"); return false },
                launch: { Issue.record("diagnostics must not launch Books") }
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDatabase(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close_v2(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }

    private static let librarySQL = """
    CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
    CREATE TABLE ZBKCOLLECTION(
      Z_PK INTEGER PRIMARY KEY,
      Z_ENT INTEGER,
      Z_OPT INTEGER,
      ZDELETEDFLAG INTEGER,
      ZHIDDEN INTEGER,
      ZPLACEHOLDER INTEGER,
      ZSORTKEY INTEGER,
      ZSORTMODE INTEGER,
      ZVIEWMODE INTEGER,
      ZLASTMODIFICATION REAL,
      ZLOCALMODDATE REAL,
      ZCOLLECTIONID TEXT,
      ZDETAILS TEXT,
      ZTITLE TEXT
    );
    CREATE TABLE ZBKCOLLECTIONMEMBER(
      Z_PK INTEGER PRIMARY KEY,
      Z_ENT INTEGER,
      Z_OPT INTEGER,
      ZSORTKEY INTEGER,
      ZASSET INTEGER,
      ZCOLLECTION INTEGER,
      ZLOCALMODDATE REAL,
      ZASSETID TEXT,
      ZTEMPORARYASSETID TEXT
    );
    CREATE TABLE ZBKLIBRARYASSET(
      Z_PK INTEGER PRIMARY KEY,
      ZASSETID TEXT,
      ZTITLE TEXT,
      ZGENRE TEXT,
      ZPATH TEXT,
      ZCONTENTTYPE INTEGER,
      ZISFINISHED INTEGER,
      ZREADINGPROGRESS REAL,
      ZLASTOPENDATE REAL
    );
    INSERT INTO Z_PRIMARYKEY VALUES ('BKCollection',7,1),('BKCollectionMember',8,1);
    """

    private static let annotationSQL = """
    CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
    CREATE TABLE ZAEANNOTATION(
      Z_PK INTEGER PRIMARY KEY,
      Z_ENT INTEGER,
      Z_OPT INTEGER,
      ZANNOTATIONUUID TEXT,
      ZANNOTATIONASSETID TEXT,
      ZANNOTATIONDELETED INTEGER,
      ZANNOTATIONSTYLE INTEGER,
      ZANNOTATIONTYPE INTEGER,
      ZANNOTATIONCREATIONDATE REAL,
      ZANNOTATIONMODIFICATIONDATE REAL,
      ZANNOTATIONSELECTEDTEXT TEXT,
      ZANNOTATIONREPRESENTATIVETEXT TEXT,
      ZANNOTATIONNOTE TEXT
    );
    INSERT INTO Z_PRIMARYKEY VALUES ('AEAnnotation',11,1);
    """
}
