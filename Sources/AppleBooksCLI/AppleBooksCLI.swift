import ArgumentParser

struct AppleBooksCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "applebookscli",
        abstract: "Read and manage Apple Books data from the command line.",
        version: AppleBooksCLIVersion.current,
        subcommands: [
            DoctorCommand.self,
            BooksCommand.self,
            ReadingCommand.self,
            StatsCommand.self,
            ContentCommand.self,
            AnnotationsCommand.self,
        ]
    )
}
