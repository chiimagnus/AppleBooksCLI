import ArgumentParser
import Foundation

enum CLIEntrypoint {
    static func run(arguments: [String]) -> Int32 {
        run(
            arguments: arguments,
            stdout: { write($0, to: .standardOutput) },
            stderr: { write($0, to: .standardError) }
        )
    }

    static func run(
        arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        let command: any ParsableCommand
        do {
            command = try AppleBooksCLI.parseAsRoot(arguments)
        } catch {
            return presentArgumentParser(error, stdout: stdout, stderr: stderr)
        }

        var runnable = command
        do {
            try runnable.run()
            return ExitCode.success.rawValue
        } catch {
            return presentArgumentParser(error, stdout: stdout, stderr: stderr)
        }
    }

    private static func presentArgumentParser(
        _ error: Error,
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        let exitCode = AppleBooksCLI.exitCode(for: error)
        let message = AppleBooksCLI.fullMessage(for: error)
        if message.isEmpty == false {
            if exitCode.isSuccess {
                stdout(message)
            } else {
                stderr(message)
            }
        }
        return exitCode.rawValue
    }

    private static func write(_ text: String, to handle: FileHandle) {
        let suffix = text.hasSuffix("\n") ? "" : "\n"
        handle.write(Data((text + suffix).utf8))
    }
}
