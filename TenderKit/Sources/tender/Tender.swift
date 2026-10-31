import ArgumentParser
import Foundation
import TenderClient
import TenderCore

@main
struct Tender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tender",
        abstract: "Manage processes across your Macs.",
        subcommands: [Start.self, Stop.self, Restart.self, Delete.self, List.self, Logs.self, Releases.self, Rollback.self, Adopt.self, Gc.self, Version.self, Daemon.self,
                      Token.self, Join.self, Nodes.self, Node.self, CA.self, ApiToken.self, Context.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of a table.")
    var json = false

    @Option(help: "tenderd's Unix socket. Defaults to $TENDER_SOCKET, then the dev socket, then production.")
    var socket: String?

    @Flag(help: "Talk to the head set with `tender context set`, even if a local daemon is running.")
    var remote = false

    /// An explicit socket, else `--remote`, else a local daemon, else the saved context.
    func makeClient() throws -> TenderClient {
        let environment = ProcessInfo.processInfo.environment
        if let socket { return TenderClient(socketPath: socket) }
        let path = TenderClient.defaultSocketPath(environment: environment)
        let hasLocalSocket = FileManager.default.fileExists(atPath: path)
        if remote || (!hasLocalSocket && environment["TENDER_SOCKET"] == nil) {
            if let saved = try ClientContextStore.standard().load() {
                return TenderClient(head: saved.context.head, caPEM: saved.context.caPEM, token: saved.token)
            }
            if remote { throw ValidationError("No head configured. Run `tender context set --head <address> --token <token>`.") }
        }
        return TenderClient(socketPath: path)
    }

    /// Runs a call and prints its JSON, or a line of text, or the error on failure.
    func run<T: Encodable>(_ call: (TenderClient) async throws -> T, text: (T) -> String) async throws {
        do {
            let value = try await call(try makeClient())
            print(json ? try encode(value) : text(value))
        } catch let error as TenderClientError {
            try fail(error)
        }
    }

    /// Runs one API call and prints its result, or the error on failure.
    func fail(_ error: TenderClientError) throws -> Never {
        if json {
            print(try encode(APIErrorBody(code: error.code, message: error.description)))
        } else {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
        }
        throw ExitCode.failure
    }

    func execute(_ call: (TenderClient) async throws -> ProcessList) async throws {
        do {
            let list = try await call(try makeClient())
            print(json ? try encode(list) : ProcessTable.render(list))
        } catch let error as TenderClientError {
            try fail(error)
        }
    }

    func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension Tender {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a service.",
            discussion: "With a command after `--`, creates or updates the service. Without one, starts an existing service."
        )

        @Argument(help: "Service name.")
        var name: String

        @Option(help: "Number of instances.")
        var instances = 1

        @Option(name: .customLong("env"), help: "Environment variable as KEY=VALUE. Repeatable.")
        var environment: [String] = []

        @Option(help: "Working directory. Defaults to /.")
        var cwd: String?

        @Option(help: "Account to run as in production. Ignored in dev mode.")
        var user = ServiceSpec.defaultUser

        @Option(help: "Node to run on. Defaults to the node you're talking to.")
        var node: String?

        @OptionGroup var options: CommonOptions

        @Argument(parsing: .postTerminator, help: "Command to run, after `--`.")
        var command: [String] = []

        func run() async throws {
            guard let executable = command.first else {
                try await options.execute { try await $0.start(service: name, node: node) }
                return
            }
            let spec = ServiceSpec(
                name: name,
                program: .executable(try Self.resolve(executable)),
                arguments: Array(command.dropFirst()),
                environment: try Self.parse(environment),
                workingDirectory: cwd,
                instances: instances,
                node: node.map { NodeID($0) },
                user: user
            )
            try await options.execute { try await $0.start(spec) }
        }

        /// launchd needs an absolute path. Resolves like a shell does.
        static func resolve(
            _ executable: String,
            path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
        ) throws -> String {
            let files = FileManager.default
            if executable.contains("/") {
                return URL(filePath: executable, relativeTo: URL(filePath: files.currentDirectoryPath))
                    .standardizedFileURL.path(percentEncoded: false)
            }
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/\(executable)"
                if files.isExecutableFile(atPath: candidate) { return candidate }
            }
            throw ValidationError("'\(executable)' was not found in PATH.")
        }

        static func parse(_ pairs: [String]) throws -> [String: String] {
            var result: [String: String] = [:]
            for pair in pairs {
                guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                    throw ValidationError("--env expects KEY=VALUE, got '\(pair)'.")
                }
                result[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
            }
            return result
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a service and keep its definition.")
        @Argument(help: "Service name.") var name: String
        @Option(help: "Only on this node. Defaults to every node running it.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.stop(service: name, node: node) }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart a service, starting it if stopped.")
        @Argument(help: "Service name.") var name: String
        @Option(help: "Only on this node. Defaults to every node running it.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.restart(service: name, node: node) }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a service and remove its definition.")
        @Argument(help: "Service name.") var name: String
        @Option(help: "Only on this node. Defaults to every node running it.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.delete(service: name, node: node) }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List managed processes.")
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.list() }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a service's stdout and stderr.")

        @Argument(help: "Service name.") var name: String
        @Flag(name: .shortAndLong, help: "Keep printing new lines.") var follow = false
        @Option(name: [.customShort("n"), .long], help: "Lines to show per file.") var lines = 200
        @Option(help: "Only this instance.") var instance: Int?
        @Option(help: "Only this stream: out or err.") var stream: String?
        @Option(help: "Only this node.") var node: String?
        @Option(help: "Only lines newer than this, like 1h or 30m.") var since: String?
        @Option(help: "Only lines containing these words.") var grep: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            var selected: LogLine.Stream?
            if let stream {
                guard let parsed = LogLine.Stream(rawValue: stream) else {
                    throw ValidationError("--stream must be out or err.")
                }
                selected = parsed
            }
            do {
                let client = try options.makeClient()
                let query = LogQuery(service: name, node: node, stream: selected,
                                     since: try since.map { try Self.parseSince($0) }, text: grep, limit: lines)
                // A head answers with every node's logs. A worker has only its own.
                do {
                    try await runCluster(client: client, query: query)
                } catch let error as TenderClientError where error.code == "http_404" {
                    if since != nil || grep != nil || node != nil {
                        throw ValidationError("--since, --grep and --node need a head. This daemon is a worker.")
                    }
                    try await runLocal(client: client, stream: selected)
                }
            } catch let error as TenderClientError {
                try options.fail(error)
            }
        }

        /// `1h`, `30m`, `2d`, `45s`.
        static func parseSince(_ text: String, now: Date = Date()) throws -> Date {
            let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
            guard let unit = text.last.flatMap({ units[$0] }), let amount = Double(text.dropLast()), amount >= 0 else {
                throw ValidationError("--since expects something like 45s, 30m, 1h or 2d.")
            }
            return now.addingTimeInterval(-amount * unit)
        }

        private func runCluster(client: TenderClient, query: LogQuery) async throws {
            let result = try await client.searchLogs(query)
            if options.json, !follow {
                print(try options.encode(result))
                return
            }
            for gap in result.gaps {
                print("-- \(gap.node?.rawValue ?? "?") dropped \(gap.droppedLines) lines --")
            }
            result.entries.forEach(emit)
            if follow {
                var live = query
                live.since = nil
                for try await entry in client.followClusterLogs(live) { emit(entry) }
            }
        }

        private func emit(_ entry: LogEntry) {
            if options.json, let data = try? JSONEncoder().encode(entry) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                let time = ISO8601DateFormatter().string(from: entry.nodeTime)
                print("\(time) \(entry.node)/\(entry.service)[\(entry.instance)] \(entry.stream.rawValue) | \(entry.line)")
            }
            fflush(stdout)
        }

        private func runLocal(client: TenderClient, stream: LogLine.Stream?) async throws {
            if follow {
                for try await line in client.followLogs(service: name, lines: lines, instance: instance, stream: stream) {
                    emit(line, compact: true)
                }
            } else {
                let response = try await client.logs(service: name, lines: lines, instance: instance, stream: stream)
                if options.json {
                    print(try options.encode(response))
                } else {
                    response.lines.forEach { emit($0, compact: false) }
                }
            }
        }

        private func emit(_ line: LogLine, compact: Bool) {
            if options.json, compact, let data = try? JSONEncoder().encode(line) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("\(line.service)[\(line.instance)] \(line.stream.rawValue) | \(line.text)")
            }
            fflush(stdout)
        }
    }

    struct Releases: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a service's releases, newest first.")
        @Argument(help: "Service name.") var name: String
        @Option(help: "Node to ask. Defaults to the node you're talking to.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            do {
                let client = try options.makeClient()
                let list = try await client.releases(service: name, node: node)
                print(options.json ? try options.encode(list) : ProcessTable.render(list))
            } catch let error as TenderClientError {
                try options.fail(error)
            }
        }
    }

    struct Rollback: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Go back to an earlier release.")
        @Argument(help: "Service name.") var name: String
        @Option(help: "Release to go back to. Defaults to the one before the current release.") var to: String?
        @Option(help: "Only on this node. Defaults to every node running it.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.rollback(service: name, to: to, node: node) }
        }
    }

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage an existing launchd job without rewriting its plist.",
            discussion: "Control it with `tender stop|start|restart <label>` and read it with `tender logs <label>`."
        )
        @Argument(help: "launchd label, for example homebrew.mxcl.mongodb-community.") var label: String
        @Option(help: "Log file to use instead of the job's StandardOutPath and StandardErrorPath.") var logPath: String?
        @Flag(help: "Stop managing the job. The job itself isn't touched.") var forget = false
        @Option(help: "Node the job runs on. Defaults to the node you're talking to.") var node: String?
        @OptionGroup var options: CommonOptions

        func validate() throws {
            if forget, logPath != nil { throw ValidationError("--forget and --log-path don't go together.") }
        }

        func run() async throws {
            if forget {
                try await options.execute { try await $0.forget(label: label, node: node) }
            } else {
                try await options.execute { try await $0.adopt(label: label, logPath: logPath, node: node) }
            }
        }
    }

    struct Gc: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot out orphaned launchd jobs with Tender's prefix.")
        @Option(help: "Node to clean. Defaults to the node you're talking to.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.collectGarbage(node: node) }
        }
    }

    struct Version: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the CLI version.")
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            print(json ? #"{"version":"\#(TenderVersion.current)"}"# : TenderVersion.current)
        }
    }
}
