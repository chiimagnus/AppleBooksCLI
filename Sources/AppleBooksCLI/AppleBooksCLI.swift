import ArgumentParser
import Foundation

struct AppleBooksCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "applebookscli",
        abstract: "Read and manage Apple Books data from the command line.",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        subcommands: [
            DoctorCommand.self,
            BooksCommand.self,
            ReadingCommand.self,
            StatsCommand.self,
            ContentCommand.self,
            AnnotationsCommand.self,
            CollectionsCommand.self,
            SyncCommand.self,
            PDFCommand.self,
            ExportCommand.self,
            BackupsCommand.self,
        ]
    )
}
