import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Use this AppleBooksCLI configuration file.")
    var config: String?

    @Option(name: .long, help: "Override the Apple Books library database file.")
    var libraryDB: String?

    @Option(name: .long, help: "Override the Apple Books annotations database file.")
    var annotationsDB: String?

    @Flag(name: .long, help: "Emit machine-readable JSON for operational commands.")
    var json = false

    @Flag(name: .long, help: "Emit additional diagnostics to standard error.")
    var verbose = false
}
