import ArgumentParser
import Foundation
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("OutputContractTests")
struct OutputContractTests {
    @Test
    func parseFailureIsSanitizedJsonOnStderrOnly() throws {
        let sentinel = "secret-value-DO-NOT-ECHO"
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["books", "list", "--definitely-unknown", sentinel],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains(sentinel) == false)
        #expect(capture.stderr.contains("definitely-unknown") == false)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope == CLIErrorEnvelope(.usageInvalid("Invalid command-line arguments.")))
        #expect(envelope.error.reason == nil)
        #expect(envelope.error.recoveryHint == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(capture.stderr.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["reason"] is NSNull)
        #expect(error["recoveryHint"] is NSNull)
    }

    @Test
    func removedJsonAndVerboseFlagsAreNotCompatibilityAliases() throws {
        for removedFlag in ["--json", "--verbose"] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["books", "list", removedFlag],
                output: capture.output
            )

            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try decodeError(capture.stderr)
            #expect(envelope.error.code == .usageInvalid)
            #expect(envelope.error.message == "Invalid command-line arguments.")
            #expect(capture.stderr.contains(removedFlag) == false)
        }
    }

    @Test
    func helpAndVersionRemainPlainTextCleanExits() {
        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["--help"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stderr.isEmpty)
        #expect(help.stdout.contains("USAGE:"))
        #expect((try? JSONSerialization.jsonObject(with: Data(help.stdout.utf8))) == nil)

        let version = Capture()
        let versionCode = CLIEntrypoint.run(arguments: ["--version"], output: version.output)
        #expect(versionCode == CLIProcessExit.success.rawValue)
        #expect(version.stderr.isEmpty)
        #expect(version.stdout == "dev")
    }

    @Test
    func typedErrorsHaveStableCodesMessagesAndExitNumbersOnStderr() throws {
        let cases: [(CLIError, CLIErrorCode, CLIProcessExit)] = [
            (.usageInvalid("bad usage"), .usageInvalid, .usageInvalid),
            (.notFound("missing"), .notFound, .notFound),
            (.unavailable("unavailable"), .unavailable, .unavailable),
            (.internalFailure, .internal, .internal),
            (.writeSafety("unsafe write"), .writeSafety, .writeSafety),
            (.permission("denied"), .permission, .permission),
        ]

        for (error, expectedCode, expectedExit) in cases {
            let capture = Capture()
            let code = CLIEntrypoint.presentRunError(error, output: capture.output)
            #expect(code == expectedExit.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try decodeError(capture.stderr)
            #expect(envelope.error.code == expectedCode)
            #expect(envelope.error.message == error.message)
            #expect(envelope.error.reason == nil)
            #expect(envelope.error.recoveryHint == nil)
        }
    }

    @Test
    func publicReasonsHaveStableExitCategoriesAndRecoveryHints() throws {
        let cases: [(CLIErrorReason, CLIError, CLIProcessExit, Bool)] = [
            (.ambiguousIdentity, .unavailableWithReason(message: "sanitized", reason: .ambiguousIdentity), .unavailable, true),
            (.annotationNotFound, .notFoundWithReason(message: "sanitized", reason: .annotationNotFound), .notFound, true),
            (.annotationRestoreUnavailable, .notFoundWithReason(message: "sanitized", reason: .annotationRestoreUnavailable), .notFound, false),
            (.backupNotFound, .notFoundWithReason(message: "sanitized", reason: .backupNotFound), .notFound, true),
            (.bookNotFound, .notFoundWithReason(message: "sanitized", reason: .bookNotFound), .notFound, true),
            (.chapterNotFound, .notFoundWithReason(message: "sanitized", reason: .chapterNotFound), .notFound, true),
            (.collectionNotFound, .notFoundWithReason(message: "sanitized", reason: .collectionNotFound), .notFound, true),
            (.configurationInvalid, .unavailableWithReason(message: "sanitized", reason: .configurationInvalid), .unavailable, true),
            (.contentUnavailable, .unavailableWithReason(message: "sanitized", reason: .contentUnavailable), .unavailable, true),
            (.contextUnavailable, .unavailableWithReason(message: "sanitized", reason: .contextUnavailable), .unavailable, true),
            (.cursorStale, .unavailableWithReason(message: "sanitized", reason: .cursorStale), .unavailable, true),
            (.databaseUnavailable, .unavailableWithReason(message: "sanitized", reason: .databaseUnavailable), .unavailable, true),
            (.historyEntryNotFound, .notFoundWithReason(message: "sanitized", reason: .historyEntryNotFound), .notFound, true),
            (.historyEntryNotFound, .notFoundWithReason(message: "sanitized", reason: .historyEntryNotFound), .notFound, true),
            (.historyUnavailable, .unavailableWithReason(message: "sanitized", reason: .historyUnavailable), .unavailable, true),
            (.operationIDConflict, .usageInvalidWithReason(message: "sanitized", reason: .operationIDConflict), .usageInvalid, true),
            (.operationIDInvalid, .usageInvalidWithReason(message: "sanitized", reason: .operationIDInvalid), .usageInvalid, true),
            (.operationReplayBlocked, .unavailableWithReason(message: "sanitized", reason: .operationReplayBlocked), .unavailable, true),
            (.outputExists, .writeSafetyWithReason(message: "sanitized", reason: .outputExists), .writeSafety, true),
            (.pdfSourceNotFound, .notFoundWithReason(message: "sanitized", reason: .pdfSourceNotFound), .notFound, true),
            (.pdfWorkerUnavailable, .unavailableWithReason(message: "sanitized", reason: .pdfWorkerUnavailable), .unavailable, true),
            (.readingOrderRequiresBook, .usageInvalidWithReason(message: "sanitized", reason: .readingOrderRequiresBook), .usageInvalid, true),
            (.readingPositionUnavailable, .unavailableWithReason(message: "sanitized", reason: .readingPositionUnavailable), .unavailable, false),
            (.schemaUnavailable, .unavailableWithReason(message: "sanitized", reason: .schemaUnavailable), .unavailable, true),
            (.selectorNotFound, .notFoundWithReason(message: "sanitized", reason: .selectorNotFound), .notFound, true),
            (.syncAckFailed, .unavailableWithReason(message: "sanitized", reason: .syncAckFailed), .unavailable, true),
            (.syncUnavailable, .unavailableWithReason(message: "sanitized", reason: .syncUnavailable), .unavailable, true),
            (.unsafeOutput, .writeSafetyWithReason(message: "sanitized", reason: .unsafeOutput), .writeSafety, true),
        ]
        #expect(Set(cases.map(\.0)) == Set(CLIErrorReason.allCases))

        for (reason, error, expectedExit, expectsHint) in cases {
            let capture = Capture()
            let code = CLIEntrypoint.presentRunError(error, output: capture.output)
            #expect(code == expectedExit.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try decodeError(capture.stderr)
            #expect(envelope.error.reason == reason.rawValue)
            #expect((envelope.error.recoveryHint != nil) == expectsHint)
            #expect(capture.stderr.contains("private-payload") == false)
        }
    }

    @Test
    func validationErrorMapsToUsageInvalidJsonOnStderr() throws {
        let capture = Capture()
        let code = CLIEntrypoint.presentRunError(
            ValidationError("invalid selection"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "invalid selection")
    }

    @Test
    func cleanRunExitUsesOfficialArgumentParserTextOnStdout() {
        let capture = Capture()
        let code = CLIEntrypoint.presentRunError(
            CleanExit.message("clean message"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout == "clean message")
    }

    @Test
    func unexpectedRunErrorIsSanitizedAndNeverReflectsPayload() throws {
        struct PrivateFailure: Error {
            let secret: String
        }
        let capture = Capture()

        let code = CLIEntrypoint.presentRunError(
            PrivateFailure(secret: "private-payload"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.internal.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains("private-payload") == false)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope.error.code == .internal)
        #expect(envelope.error.message == "Internal error.")
    }

    @Test
    func mutationOutcomeAlwaysEncodesAcknowledgementStateExplicitly() throws {
        let noSync = AnnotationMutationCommandResult(
            MutationResult(
                committed: false,
                backupHandle: nil,
                localPK: 1,
                stableID: "stable",
                changed: false,
                acknowledgementRequested: false,
                acknowledged: nil,
                warnings: []
            ),
            selector: .uuid("stable")
        )
        let requestedNoOp = AnnotationMutationCommandResult(
            MutationResult(
                committed: false,
                backupHandle: nil,
                localPK: 1,
                stableID: "stable",
                changed: false,
                acknowledgementRequested: true,
                acknowledged: nil,
                warnings: []
            ),
            selector: .uuid("stable")
        )

        for (result, requested) in [(noSync, false), (requestedNoOp, true)] {
            let data = try JSONEncoder().encode(result)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["acknowledgementRequested"] as? Bool == requested)
            #expect(object["acknowledged"] is NSNull)
            #expect(try JSONDecoder().decode(AnnotationMutationCommandResult.self, from: data) == result)
        }
    }

    @Test
    func mutationDomainIdentityFallsBackToExplicitLocalPKOnlyWhenStableIdentityIsUnavailable() throws {
        let annotation = AnnotationMutationCommandResult(
            MutationResult(
                committed: true,
                backupHandle: "annotations__20240101-000000-000000__00000000-0000-4000-8000-000000000001.sqlite",
                localPK: 7,
                stableID: nil,
                changed: true,
                acknowledgementRequested: false,
                acknowledged: nil,
                warnings: []
            ),
            selector: .localPK(7)
        )
        #expect(annotation.annotationUUID == nil)
        #expect(annotation.annotationLocalPK == 7)

        let membership = MembershipMutationCommandResult(
            MutationResult(
                committed: true,
                backupHandle: "library__20240101-000000-000000__00000000-0000-4000-8000-000000000002.sqlite",
                localPK: 3,
                stableID: nil,
                relatedLocalPK: 9,
                relatedStableID: nil,
                changed: false,
                acknowledgementRequested: false,
                acknowledged: nil,
                warnings: []
            ),
            collection: .localPK(3),
            book: .localPK(9)
        )
        #expect(membership.collectionID == nil)
        #expect(membership.collectionLocalPK == 3)
        #expect(membership.bookAssetID == nil)
        #expect(membership.bookLocalPK == 9)
    }

    @Test
    func genericJsonWriterEmitsOneCompactValueWithoutDiagnostics() throws {
        struct Result: Codable, Equatable {
            let value: String
        }

        let capture = Capture()
        try capture.output.writeJSON(Result(value: "ok"))
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout == #"{"value":"ok"}"#)
        #expect(try JSONDecoder().decode(Result.self, from: Data(capture.stdout.utf8)) == Result(value: "ok"))
    }

    @Test
    func diagnosticWriterUsesOneSanitizedJsonLineOnStderr() throws {
        let capture = Capture()
        try capture.output.writeDiagnostic(.historyCompletionFailed)

        #expect(capture.stdout.isEmpty)
        let decoded = try JSONDecoder().decode(
            CLIDiagnosticEnvelope.self,
            from: Data(capture.stderr.utf8)
        )
        #expect(decoded == .historyCompletionFailed)
        #expect(decoded.diagnostic.severity == .warning)
    }

    private func decodeError(_ value: String) throws -> CLIErrorEnvelope {
        try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(value.utf8))
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""

        var output: CLIOutput {
            CLIOutput(
                stdout: { [self] text in stdout += text },
                stderr: { [self] text in stderr += text }
            )
        }
    }
}
