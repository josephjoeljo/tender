import ArgumentParser

@main
struct Tender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tender",
        abstract: "Manage processes across your Macs.",
        subcommands: [List.self]
    )
}

extension Tender {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List managed processes.")
        func run() async throws {
            print("No processes yet.") // TODO(milestone 1)
        }
    }
}
