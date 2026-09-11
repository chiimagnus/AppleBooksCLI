import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: .hidden)
    var config: String?

    @Option(name: .long, help: .hidden)
    var libraryDB: String?

    @Option(name: .long, help: .hidden)
    var annotationsDB: String?
}
