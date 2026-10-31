import ArgumentParser
import TenderCore

@main
struct TenderD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tenderd",
        abstract: "Tender daemon: runs as the head node or a worker."
    )

    enum Role: String, ExpressibleByArgument { case head, worker }

    @Option(help: "Which role this daemon plays.")
    var role: Role = .worker

    @Flag(help: "Use per-user paths and the gui/<uid> launchd domain (no root needed).")
    var dev = false

    func run() async throws {
        let env: TenderEnvironment = dev ? .development : .production
        print("tenderd starting: role=\(role.rawValue) mode=\(env.mode.rawValue) root=\(env.root.path())")
        // TODO(milestone 1): start the worker agent. TODO(milestone 2): head services.
    }
}
