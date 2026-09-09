import AppleBooksCore
import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("DoctorCommandTests")
struct DoctorCommandTests {
    @Test
    func explicitOverridesAreSanitizedAndDoNotClaimCloudSync() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backupRoot = fixture.root.appendingPathComponent("missing/backups", isDirectory: true)

        let command = try DoctorCommand.parse(fixture.arguments)
        let machine = Capture()
        try command.execute(output: machine.output, backupRoot: backupRoot, installedPDFWorkerReady: true)
        #expect(machine.stderr.isEmpty)
        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(machine.stdout.utf8))
        #expect(result.status == .partial)
        #expect(result.components.libraryDatabaseReady)
        #expect(result.components.annotationsDatabaseReady)
        #expect(result.components.libraryReadReady)
        #expect(result.components.annotationsReadReady)
        #expect(result.components.collectionWriteReady)
        #expect(result.components.annotationWriteReady)
        #expect(result.components.cloudSyncReady == false)
        #expect(result.components.pdfWorkerReady)
        #expect(result.capabilities.collectionsWrite)
        #expect(result.capabilities.annotationWrite)
        #expect(result.capabilities.syncPrerequisites == false)
        #expect(result.issues.contains(.init(code: .cloudSyncUnavailable, state: .degraded)))
        #expect(machine.stdout.contains("readSchemaReady") == false)
        #expect(machine.stdout.contains("writeSchemaReady") == false)
        #expect(machine.stdout.contains(fixture.root.path) == false)
        #expect(machine.stdout.contains("ZBKLIBRARYASSET") == false)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
    }

    @Test
    func missingInstalledPDFWorkerOnlyDisablesPDFCapability() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try DoctorCommand.parse(fixture.arguments)
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            installedPDFWorkerReady: false
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .partial)
        #expect(result.components.pdfWorkerReady == false)
        #expect(result.capabilities.pdfReadPrerequisites == false)
        #expect(result.capabilities.booksRead)
        #expect(result.issues.contains(.init(code: .pdfWorkerUnavailable, state: .degraded)))
        #expect(capture.stdout.contains(fixture.root.path) == false)
    }

    @Test
    func invalidDatabaseOverrideReturnsFatalLogicalIssueWithoutPathLeak() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("private-library.sqlite")
        var arguments = fixture.arguments
        let libraryIndex = arguments.firstIndex(of: fixture.library.path)!
        arguments[libraryIndex] = missing.path

        let command = try DoctorCommand.parse(arguments)
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true)
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .partial)
        #expect(result.components.libraryDatabaseReady == false)
        #expect(result.capabilities.booksRead == false)
        #expect(result.capabilities.collectionsRead == false)
        #expect(result.capabilities.annotationWrite)
        #expect(result.issues.contains(.init(code: .libraryDatabaseInvalidOverride, state: .fatal)))
        #expect(capture.stdout.contains(missing.path) == false)
        #expect(capture.stdout.contains("private-library.sqlite") == false)
    }

    @Test
    func writeSchemaGapIsDegradedButDoesNotMutateDatabase() throws {
        let fixture = try Fixture(
            librarySQL: Self.librarySQL.replacingOccurrences(of: "  ZHIDDEN INTEGER,\n", with: "")
        )
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.library)
        let command = try DoctorCommand.parse(fixture.arguments)
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            installedPDFWorkerReady: true
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .partial)
        #expect(result.components.libraryReadReady)
        #expect(result.components.collectionWriteReady == false)
        #expect(result.capabilities.booksRead)
        #expect(result.capabilities.collectionsWrite == false)
        #expect(result.capabilities.annotationWrite)
        #expect(result.issues.contains(.init(code: .libraryWriteSchemaIncompatible, state: .degraded)))
        #expect(try Data(contentsOf: fixture.library) == before)
    }

    @Test
    func componentFailuresOnlyDisableDependentCapabilities() throws {
        do {
            let fixture = try Fixture(
                librarySQL: Self.librarySQL.replacingOccurrences(of: "  ZPATH TEXT,\n", with: "")
            )
            defer { fixture.remove() }
            let result = try doctorResult(fixture, workerReady: true)
            #expect(result.status == .partial)
            #expect(result.capabilities.booksRead)
            #expect(result.capabilities.collectionsRead)
            #expect(result.capabilities.contentReadPrerequisites == false)
            #expect(result.capabilities.annotationWrite)
        }

        do {
            let fixture = try Fixture(
                annotationsSQL: Self.annotationSQL.replacingOccurrences(
                    of: "  ZANNOTATIONNOTE TEXT,\n  ZFUTUREPROOFING6 TEXT\n",
                    with: "  ZANNOTATIONNOTE TEXT\n"
                )
            )
            defer { fixture.remove() }
            let result = try doctorResult(fixture, workerReady: true)
            #expect(result.status == .partial)
            #expect(result.components.annotationsReadReady)
            #expect(result.components.annotationWriteReady == false)
            #expect(result.capabilities.annotationsRead)
            #expect(result.capabilities.annotationWrite == false)
            #expect(result.capabilities.collectionsWrite)
        }

        do {
            let fixture = try Fixture(configData: Data("not-json".utf8))
            defer { fixture.remove() }
            let result = try doctorResult(fixture, workerReady: true)
            #expect(result.status == .partial)
            #expect(result.components.configurationReady == false)
            #expect(result.capabilities.booksRead)
            #expect(result.capabilities.collectionsRead)
            #expect(result.capabilities.annotationsRead == false)
            #expect(result.capabilities.contentReadPrerequisites == false)
            #expect(result.capabilities.annotationWrite)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let badRoot = fixture.root.appendingPathComponent("backup-file")
            try Data().write(to: badRoot)
            let result = try doctorResult(fixture, backupRoot: badRoot, workerReady: true)
            #expect(result.status == .partial)
            #expect(result.components.backupLocationReady == false)
            #expect(result.capabilities.backups == false)
            #expect(result.capabilities.collectionsWrite == false)
            #expect(result.capabilities.annotationWrite == false)
            #expect(result.capabilities.booksRead)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            var arguments = fixture.arguments
            let index = arguments.firstIndex(of: fixture.annotations.path)!
            arguments[index] = fixture.root.appendingPathComponent("missing-annotations.sqlite").path
            let result = try doctorResult(fixture, arguments: arguments, workerReady: true)
            #expect(result.status == .partial)
            #expect(result.capabilities.booksRead)
            #expect(result.capabilities.annotationsRead == false)
            #expect(result.capabilities.annotationWrite == false)
            #expect(result.capabilities.collectionsRead)
        }
    }

    @Test
    func bothDatabasesUnavailableMakesOverallUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var arguments = fixture.arguments
        arguments[arguments.firstIndex(of: fixture.library.path)!] = fixture.root.appendingPathComponent("missing-library.sqlite").path
        arguments[arguments.firstIndex(of: fixture.annotations.path)!] = fixture.root.appendingPathComponent("missing-annotations.sqlite").path

        let result = try doctorResult(fixture, arguments: arguments, workerReady: true)
        #expect(result.status == .unavailable)
        #expect(result.capabilities.all.allSatisfy { $0 == false })
        #expect(result.components.libraryDatabaseReady == false)
        #expect(result.components.annotationsDatabaseReady == false)
    }

    @Test
    func rootDispatchAcceptsLeafLocalOptionsAndEmitsOneDoctorJSONValue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["doctor"] + fixture.arguments,
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect([DoctorOverallStatus.ready, .partial, .unavailable].contains(result.status))
        #expect(capture.stdout.first == "{")
        #expect(capture.stdout.last == "}")
        #expect(capture.stdout.contains(fixture.root.path) == false)
    }

    @Test
    func rootStillRejectsOperationalOptionsBeforeCommandPath() {
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["--json", "doctor"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains(#""code":"usage_invalid""#))
        #expect(capture.stderr.contains("--json") == false)
    }

    private enum FixtureError: Error {
        case sqliteOpen(Int32)
        case sqliteExec(Int32)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL

        var arguments: [String] {
            [
                "--library-db", library.path,
                "--annotations-db", annotations.path,
                "--config", config.path,
            ]
        }

        init(
            librarySQL: String = DoctorCommandTests.librarySQL,
            annotationsSQL: String = DoctorCommandTests.annotationSQL,
            configData: Data = Data("{\"historical_assets\":{}}".utf8)
        ) throws {
            root = DoctorCommandTests().temporaryDirectory()
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try DoctorCommandTests().createDatabase(library, sql: librarySQL)
            try DoctorCommandTests().createDatabase(annotations, sql: annotationsSQL)
            try configData.write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func doctorResult(
        _ fixture: Fixture,
        arguments: [String]? = nil,
        backupRoot: URL? = nil,
        workerReady: Bool
    ) throws -> DoctorResult {
        let command = try DoctorCommand.parse(arguments ?? fixture.arguments)
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: backupRoot ?? fixture.root.appendingPathComponent("backups", isDirectory: true),
            installedPDFWorkerReady: workerReady
        )
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains(fixture.root.path) == false)
        return try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""

        var output: CLIOutput {
            CLIOutput(
                stdout: { [self] in stdout += $0 },
                stderr: { [self] in stderr += $0 }
            )
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
            throw FixtureError.sqliteOpen(open)
        }
        defer { sqlite3_close_v2(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw FixtureError.sqliteExec(result)
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
      ZANNOTATIONNOTE TEXT,
      ZFUTUREPROOFING6 TEXT
    );
    INSERT INTO Z_PRIMARYKEY VALUES ('AEAnnotation',11,1);
    """
}
