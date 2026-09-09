import ArgumentParser

protocol GlobalOptionsProviding {
    var global: GlobalOptions { get }
}

protocol CLIOutputRunnable {
    func run(output: CLIOutput) throws
}

protocol OperationHistoryRecordable {
    var historyOperation: String { get }
}

enum CLIEntrypoint {
    static func run(arguments: [String]) -> Int32 {
        run(arguments: arguments, output: .standard)
    }

    static func run(arguments: [String], output: CLIOutput) -> Int32 {
        run(arguments: arguments, output: output, historyStore: nil)
    }

    static func run(
        arguments: [String],
        output: CLIOutput,
        historyStore: OperationHistoryStore?
    ) -> Int32 {
        let command: any ParsableCommand
        do {
            command = try AppleBooksCLI.parseAsRoot(arguments)
        } catch {
            return presentParseError(error, output: output)
        }

        return runParsed(
            command,
            arguments: arguments,
            output: output,
            historyStore: historyStore
        )
    }

    static func runParsed(
        _ command: any ParsableCommand,
        arguments: [String],
        output: CLIOutput,
        historyStore: OperationHistoryStore? = nil
    ) -> Int32 {
        guard let recordable = command as? any OperationHistoryRecordable else {
            return dispatch(command, output: output)
        }

        let activeHistoryStore = historyStore ?? OperationHistoryStore()
        let token: OperationHistoryToken
        do {
            token = try activeHistoryStore.begin(operation: recordable.historyOperation, arguments: arguments)
        } catch {
            return presentRunError(
                CLIError.unavailable("Operation history is unavailable."),
                output: output
            )
        }

        var capturedStdout = ""
        var capturedStderr = ""
        let historyOutput = CLIOutput(
            stdout: { text in
                output.stdout(text)
                capturedStdout += normalizedHistoryStreamText(text)
            },
            stderr: { text in
                output.stderr(text)
                capturedStderr += normalizedHistoryStreamText(text)
            }
        )
        let exitCode = dispatch(command, output: historyOutput)
        do {
            try activeHistoryStore.complete(
                token,
                exitCode: exitCode,
                stdout: capturedStdout,
                stderr: capturedStderr
            )
        } catch {
            do {
                try output.writeDiagnostic(.historyCompletionFailed)
            } catch {
                output.stderr(#"{"diagnostic":{"code":"history_completion_failed","message":"Operation history completion was not recorded.","severity":"warning"}}"# + "\n")
            }
        }
        return exitCode
    }

    private static func dispatch(
        _ command: any ParsableCommand,
        output: CLIOutput
    ) -> Int32 {
        do {
            if let outputRunnable = command as? any CLIOutputRunnable {
                try outputRunnable.run(output: output)
            } else {
                var runnable = command
                try runnable.run()
            }
            return CLIProcessExit.success.rawValue
        } catch {
            return presentRunError(error, output: output)
        }
    }

    static func presentRunError(
        _ error: Error,
        output: CLIOutput
    ) -> Int32 {
        if let error = error as? CLIError {
            return present(error, output: output)
        }
        if let error = error as? ValidationError {
            return present(.usageInvalid(error.description), output: output)
        }

        let argumentParserExit = AppleBooksCLI.exitCode(for: error)
        if argumentParserExit.isSuccess {
            let message = AppleBooksCLI.fullMessage(for: error)
            if message.isEmpty == false { output.stdout(message) }
            return CLIProcessExit.success.rawValue
        }

        return present(.internalFailure, output: output)
    }

    private static func presentParseError(
        _ error: Error,
        output: CLIOutput
    ) -> Int32 {
        let argumentParserExit = AppleBooksCLI.exitCode(for: error)
        if argumentParserExit.isSuccess {
            let message = AppleBooksCLI.fullMessage(for: error)
            if message.isEmpty == false { output.stdout(message) }
            return CLIProcessExit.success.rawValue
        }

        return present(
            .usageInvalid("Invalid command-line arguments."),
            output: output
        )
    }

    private static func present(
        _ error: CLIError,
        output: CLIOutput
    ) -> Int32 {
        do {
            try output.writeErrorJSON(CLIErrorEnvelope(error))
        } catch {
            output.stderr(#"{"error":{"code":"internal","message":"Internal error.","reason":null,"recoveryHint":null},"ok":false}"#)
            return CLIProcessExit.internal.rawValue
        }
        return error.exitCode.rawValue
    }

    private static func normalizedHistoryStreamText(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
