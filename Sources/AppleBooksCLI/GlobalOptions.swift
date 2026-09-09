import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Use this AppleBooksCLI configuration file.")
    var config: String?

    @Option(name: .long, help: "Override the Apple Books library database file.")
    var libraryDB: String?

    @Option(name: .long, help: "Override the Apple Books annotations database file.")
    var annotationsDB: String?
}
