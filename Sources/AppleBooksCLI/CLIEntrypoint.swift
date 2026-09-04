import ArgumentParser

protocol JSONOutputProviding {
    var jsonRequested: Bool { get }
}

protocol GlobalOptionsProviding: JSONOutputProviding {
    var global: GlobalOptions { get }
}

extension GlobalOptionsProviding {
    var jsonRequested: Bool { global.json }
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
            return presentParseError(error, arguments: arguments, output: output)
        }

        let jsonRequested = (command as? any JSONOutputProviding)?.jsonRequested ?? false
        guard let recordable = command as? any OperationHistoryRecordable else {
            return dispatch(command, jsonRequested: jsonRequested, output: output)
        }

        let activeHistoryStore = historyStore ?? OperationHistoryStore()
        let token: OperationHistoryToken
        do {
            token = try activeHistoryStore.begin(operation: recordable.historyOperation, arguments: arguments)
        } catch {
            return presentRunError(
                CLIError.unavailable("Operation history is unavailable."),
                jsonRequested: jsonRequested,
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
        let exitCode = dispatch(command, jsonRequested: jsonRequested, output: historyOutput)
        do {
            try activeHistoryStore.complete(
                token,
                exitCode: exitCode,
                stdout: capturedStdout,
                stderr: capturedStderr
            )
        } catch {
            output.stderr("Warning: Operation history completion was not recorded.")
        }
        return exitCode
    }

    private static func dispatch(
        _ command: any ParsableCommand,
        jsonRequested: Bool,
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
            return presentRunError(error, jsonRequested: jsonRequested, output: output)
        }
    }

    static func presentRunError(
        _ error: Error,
        jsonRequested: Bool,
        output: CLIOutput
    ) -> Int32 {
        if let error = error as? CLIError {
            return present(error, jsonRequested: jsonRequested, output: output)
        }
        if let error = error as? ValidationError {
            return present(
                .usageInvalid(error.description),
                jsonRequested: jsonRequested,
                output: output
            )
        }

        let argumentParserExit = AppleBooksCLI.exitCode(for: error)
        if argumentParserExit.isSuccess {
            let message = AppleBooksCLI.fullMessage(for: error)
            if message.isEmpty == false { output.stdout(message) }
            return CLIProcessExit.success.rawValue
        }

        return present(.internalFailure, jsonRequested: jsonRequested, output: output)
    }

    private static func presentParseError(
        _ error: Error,
        arguments: [String],
        output: CLIOutput
    ) -> Int32 {
        let argumentParserExit = AppleBooksCLI.exitCode(for: error)
        if argumentParserExit.isSuccess {
            let message = AppleBooksCLI.fullMessage(for: error)
            if message.isEmpty == false { output.stdout(message) }
            return CLIProcessExit.success.rawValue
        }

        guard rawJSONRequested(arguments) else {
            let message = AppleBooksCLI.fullMessage(for: error)
            if message.isEmpty == false { output.stderr(message) }
            return CLIProcessExit.usageInvalid.rawValue
        }

        let message = AppleBooksCLI.message(for: error)
        return present(
            .usageInvalid(message.isEmpty ? "Invalid command-line arguments." : message),
            jsonRequested: true,
            output: output
        )
    }

    private static func present(
        _ error: CLIError,
        jsonRequested: Bool,
        output: CLIOutput
    ) -> Int32 {
        if jsonRequested {
            do {
                try output.writeJSON(CLIErrorEnvelope(error))
            } catch {
                output.stderr("Error: Internal error.")
                return CLIProcessExit.internal.rawValue
            }
        } else {
            output.stderr("Error: \(error.message)")
        }
        return error.exitCode.rawValue
    }

    private static func normalizedHistoryStreamText(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func rawJSONRequested(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--" { return false }
            if argument == "--json" { return true }
        }
        return false
    }
}
