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

enum CLIEntrypoint {
    static func run(arguments: [String]) -> Int32 {
        run(arguments: arguments, output: .standard)
    }

    static func run(arguments: [String], output: CLIOutput) -> Int32 {
        let command: any ParsableCommand
        do {
            command = try AppleBooksCLI.parseAsRoot(arguments)
        } catch {
            return presentParseError(error, arguments: arguments, output: output)
        }

        let jsonRequested = (command as? any JSONOutputProviding)?.jsonRequested ?? false
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

    private static func rawJSONRequested(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--" { return false }
            if argument == "--json" { return true }
        }
        return false
    }
}
