import ArgumentParser

protocol GlobalOptionsProviding {
    var global: GlobalOptions { get }
}

protocol CLIOutputRunnable {
    func run(output: CLIOutput) throws
}

protocol OperationHistoryRecordable: CLIOutputRunnable {
    var historyOperation: String { get }
    func historyRequest() throws -> OperationHistoryRequest
    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws
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
        arguments _: [String],
        output: CLIOutput,
        historyStore: OperationHistoryStore? = nil
    ) -> Int32 {
        guard let recordable = command as? any OperationHistoryRecordable else {
            return dispatch(command, output: output)
        }

        let request: OperationHistoryRequest
        do {
            request = try recordable.historyRequest()
        } catch {
            return presentRunError(error, output: output)
        }

        let activeHistoryStore = historyStore ?? OperationHistoryStore()
        let token: OperationHistoryToken
        do {
            token = try activeHistoryStore.begin(operation: recordable.historyOperation, request: request)
        } catch {
            return presentRunError(
                CLIError.unavailable("Operation history is unavailable."),
                output: output
            )
        }

        let sink = OperationHistoryCompletionSink()
        let exitCode = dispatchRecordable(recordable, output: output, sink: sink)
        do {
            try activeHistoryStore.complete(
                token,
                exitCode: exitCode,
                completion: sink.completion
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

    private static func dispatchRecordable(
        _ command: any OperationHistoryRecordable,
        output: CLIOutput,
        sink: OperationHistoryCompletionSink
    ) -> Int32 {
        do {
            try command.runForHistory(output: output, sink: sink)
            return CLIProcessExit.success.rawValue
        } catch {
            return presentRunError(error, output: output)
        }
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

}
