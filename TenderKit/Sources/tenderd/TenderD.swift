import ArgumentParser
import TenderAgent
import TenderCore

@main
struct TenderD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tenderd",
        abstract: "Tender daemon: runs as the head node or a worker."
    )

    enum Role: String, ExpressibleByArgument { case head, worker }

    @Option(help: "Which role this daemon plays. Head services arrive in milestone 2; both run the worker agent.")
    var role: Role = .worker

    @Flag(help: "Use per-user paths and the gui/<uid> launchd domain (no root needed).")
    var dev = false

    func run() async throws {
        let env: TenderEnvironment = dev ? .development : .production
        print("tenderd starting: role=\(role.rawValue) mode=\(env.mode.rawValue) root=\(env.root.path())")
        try await AgentRuntime(environment: env).run()
    }
}
