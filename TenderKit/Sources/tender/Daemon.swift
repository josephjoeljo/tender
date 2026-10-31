import ArgumentParser
import Foundation
import LaunchdKit
import TenderCore

extension Tender {
    struct Daemon: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or remove tenderd's own launchd job.",
            subcommands: [Install.self, Uninstall.self]
        )

        /// Production install (`--system`) arrives with milestone 1 step G.
        static func requireDev(_ dev: Bool) throws {
            guard dev else { throw ValidationError("Only --dev is supported for now.") }
        }

        static func bootoutAndWait(_ launchctl: Launchctl, label: String) async throws {
            do {
                try await launchctl.bootout(label: label)
            } catch LaunchctlError.notFound {
                return
            }
            for _ in 0..<100 {
                if try await launchctl.print(label: label) == nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Run tenderd under launchd so it survives logout and reboot. Re-running upgrades it."
            )

            @Flag(help: "Per-user install: ~/Library/LaunchAgents and the gui/<uid> domain.")
            var dev = false

            @Option(help: "Path to the tenderd binary. Defaults to the one next to this `tender`.")
            var tenderdPath: String?

            func run() async throws {
                try Daemon.requireDev(dev)
                let environment = TenderEnvironment.development
                let tenderd = try tenderdPath ?? Self.siblingTenderd()
                guard FileManager.default.isExecutableFile(atPath: tenderd) else {
                    throw ValidationError("'\(tenderd)' is not executable. Pass --tenderd-path.")
                }

                let label = environment.agentLabel
                let files = FileManager.default
                try files.createDirectory(at: environment.logsDirectory, withIntermediateDirectories: true)
                try files.createDirectory(at: environment.plistDirectory, withIntermediateDirectories: true)
                let plist = environment.plistPath(label: label)
                try PlistRenderer().render(
                    label: label,
                    programArguments: [tenderd, "--role", "worker", "--dev"],
                    stdoutPath: environment.logsDirectory.appending(path: "tenderd.out.log").path(percentEncoded: false),
                    stderrPath: environment.logsDirectory.appending(path: "tenderd.err.log").path(percentEncoded: false)
                ).write(to: plist, options: .atomic)

                let launchctl = Launchctl(domain: .forEnvironment(environment))
                try await Daemon.bootoutAndWait(launchctl, label: label)
                try await launchctl.enable(label: label)
                try await launchctl.bootstrap(plistURL: plist)

                let socket = environment.socketPath.path(percentEncoded: false)
                for _ in 0..<100 where !files.fileExists(atPath: socket) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard files.fileExists(atPath: socket) else {
                    throw ValidationError("tenderd did not open \(socket). See \(environment.logsDirectory.path(percentEncoded: false))tenderd.err.log")
                }
                print("Installed \(label) running \(tenderd)")
            }

            private static func siblingTenderd() throws -> String {
                guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                    throw ValidationError("Can't locate this executable. Pass --tenderd-path.")
                }
                return executable.deletingLastPathComponent().appending(path: "tenderd").path(percentEncoded: false)
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove tenderd's launchd job. Managed services keep running."
            )

            @Flag(help: "Per-user install.")
            var dev = false

            func run() async throws {
                try Daemon.requireDev(dev)
                let environment = TenderEnvironment.development
                let label = environment.agentLabel
                try await Daemon.bootoutAndWait(Launchctl(domain: .forEnvironment(environment)), label: label)
                try? FileManager.default.removeItem(at: environment.plistPath(label: label))
                print("Uninstalled \(label)")
            }
        }
    }
}
