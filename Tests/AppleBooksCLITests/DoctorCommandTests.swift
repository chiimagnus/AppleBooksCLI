import AppleBooksCore
import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("DoctorCommandTests")
struct DoctorCommandTests {
    @Test
    func readyHumanAndJSONResultsShareTheSameSanitizedModel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backupRoot = fixture.root.appendingPathComponent("missing/backups", isDirectory: true)

        let humanCommand = try DoctorCommand.parse(fixture.arguments)
        let human = Capture()
        try humanCommand.execute(output: human.output, backupRoot: backupRoot)
        #expect(human.stderr.isEmpty)
        #expect(human.stdout.contains("AppleBooksCLI doctor: ready"))
        #expect(human.stdout.contains("library database: ready"))
        #expect(human.stdout.contains(fixture.root.path) == false)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)

        var jsonArguments = fixture.arguments
        jsonArguments.append("--json")
        let jsonCommand = try DoctorCommand.parse(jsonArguments)
        let machine = Capture()
        try jsonCommand.execute(output: machine.output, backupRoot: backupRoot)
        #expect(machine.stderr.isEmpty)
        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(machine.stdout.utf8))
        #expect(result.status == .ready)
        #expect(result.libraryDatabaseReady)
        #expect(result.annotationsDatabaseReady)
        #expect(result.readSchemaReady)
        #expect(result.writeSchemaReady)
        #expect(machine.stdout.contains(fixture.root.path) == false)
        #expect(machine.stdout.contains("ZBKLIBRARYASSET") == false)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
    }

    @Test
    func missingInstalledPDFWorkerIsDegradedOnlyWhenPackagingProbeIsExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try DoctorCommand.parse(fixture.arguments + ["--json"])
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true),
            installedPDFWorkerReady: false
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .degraded)
        #expect(result.installedPDFWorkerReady == false)
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
        arguments.append("--json")

        let command = try DoctorCommand.parse(arguments)
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true)
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .fatal)
        #expect(result.libraryDatabaseReady == false)
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
        let command = try DoctorCommand.parse(fixture.arguments + ["--json"])
        let capture = Capture()
        try command.execute(
            output: capture.output,
            backupRoot: fixture.root.appendingPathComponent("backups", isDirectory: true)
        )

        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .degraded)
        #expect(result.readSchemaReady)
        #expect(result.writeSchemaReady == false)
        #expect(result.issues.contains(.init(code: .libraryWriteSchemaIncompatible, state: .degraded)))
        #expect(try Data(contentsOf: fixture.library) == before)
    }

    @Test
    func rootDispatchAcceptsLeafLocalOptionsAndEmitsOneDoctorJSONValue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["doctor"] + fixture.arguments + ["--json"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let result = try JSONDecoder().decode(DoctorResult.self, from: Data(capture.stdout.utf8))
        #expect(result.status == .ready || result.status == .degraded)
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
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains(#""code":"usage_invalid""#))
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

        init(librarySQL: String = DoctorCommandTests.librarySQL) throws {
            root = DoctorCommandTests().temporaryDirectory()
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try DoctorCommandTests().createDatabase(library, sql: librarySQL)
            try DoctorCommandTests().createDatabase(annotations, sql: DoctorCommandTests.annotationSQL)
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
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
