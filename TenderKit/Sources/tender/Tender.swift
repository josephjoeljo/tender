import ArgumentParser
import Foundation
import TenderClient
import TenderCore

@main
struct Tender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tender",
        abstract: "Manage processes across your Macs.",
        subcommands: [Start.self, Stop.self, Restart.self, Delete.self, List.self, Logs.self, Releases.self, Rollback.self, Gc.self, Version.self, Daemon.self]
    )
}

struct CommonOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of a table.")
    var json = false

    @Option(help: "tenderd's Unix socket. Defaults to $TENDER_SOCKET, then the dev socket, then production.")
    var socket: String?

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
        let client = TenderClient(socketPath: socket ?? TenderClient.defaultSocketPath())
        do {
            let list = try await call(client)
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

        @Option(help: "Working directory. Defaults to the current directory.")
        var cwd: String?

        @OptionGroup var options: CommonOptions

        @Argument(parsing: .postTerminator, help: "Command to run, after `--`.")
        var command: [String] = []

        func run() async throws {
            guard let executable = command.first else {
                try await options.execute { try await $0.start(service: name) }
                return
            }
            let spec = ServiceSpec(
                name: name,
                program: .executable(try Self.resolve(executable)),
                arguments: Array(command.dropFirst()),
                environment: try Self.parse(environment),
                workingDirectory: cwd ?? FileManager.default.currentDirectoryPath,
                instances: instances
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
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.stop(service: name) }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart a service, starting it if stopped.")
        @Argument(help: "Service name.") var name: String
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.restart(service: name) }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a service and remove its definition.")
        @Argument(help: "Service name.") var name: String
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.delete(service: name) }
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
        @OptionGroup var options: CommonOptions

        func run() async throws {
            var selected: LogLine.Stream?
            if let stream {
                guard let parsed = LogLine.Stream(rawValue: stream) else {
                    throw ValidationError("--stream must be out or err.")
                }
                selected = parsed
            }
            let client = TenderClient(socketPath: options.socket ?? TenderClient.defaultSocketPath())
            do {
                if follow {
                    for try await line in client.followLogs(service: name, lines: lines, instance: instance, stream: selected) {
                        emit(line, compact: true)
                    }
                } else {
                    let response = try await client.logs(service: name, lines: lines, instance: instance, stream: selected)
                    if options.json {
                        print(try options.encode(response))
                    } else {
                        response.lines.forEach { emit($0, compact: false) }
                    }
                }
            } catch let error as TenderClientError {
                try options.fail(error)
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
        @OptionGroup var options: CommonOptions

        func run() async throws {
            let client = TenderClient(socketPath: options.socket ?? TenderClient.defaultSocketPath())
            do {
                let list = try await client.releases(service: name)
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
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.rollback(service: name, to: to) }
        }
    }

    struct Gc: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot out orphaned launchd jobs with Tender's prefix.")
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.execute { try await $0.collectGarbage() }
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
