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

        struct Mode: ParsableArguments {
            @Flag(help: "Per-user install: ~/Library/LaunchAgents and the gui/<uid> domain.")
            var dev = false

            @Flag(help: "Production install: /opt/tender, /Library/LaunchDaemons and the system domain. Needs root.")
            var system = false

            func validate() throws {
                guard dev != system else { throw ValidationError("Pass exactly one of --dev or --system.") }
            }

            var environment: TenderEnvironment { system ? .production : .development }
        }

        static func requireRoot(_ command: String) throws {
            guard getuid() == 0 else { throw ValidationError("--system needs root. Run: sudo tender daemon \(command) --system") }
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

        /// Replaces the daemon's job with the plist and waits for its socket.
        static func load(plist: URL, environment: TenderEnvironment) async throws {
            let label = environment.agentLabel
            let launchctl = Launchctl(domain: .forEnvironment(environment))
            try await bootoutAndWait(launchctl, label: label)
            try await launchctl.enable(label: label)
            try await launchctl.bootstrap(plistURL: plist)

            let socket = environment.socketPath.path(percentEncoded: false)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: socket) else {
                let log = environment.logsDirectory.appending(path: "tenderd.err.log").path(percentEncoded: false)
                throw ValidationError("tenderd did not open \(socket). See \(log)")
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Run tenderd under launchd so it survives logout and reboot. Re-running upgrades it."
            )

            @OptionGroup var mode: Mode

            @Option(help: "Path to the tenderd binary. Defaults to the one next to this `tender`.")
            var tenderdPath: String?

            @Flag(help: "With --system: print what would be done and change nothing. Doesn't need root.")
            var dryRun = false

            func validate() throws {
                if dryRun, !mode.system { throw ValidationError("--dry-run only applies to --system.") }
            }

            func run() async throws {
                let tenderd = try tenderdPath ?? Self.siblingTenderd()
                guard FileManager.default.isExecutableFile(atPath: tenderd) else {
                    throw ValidationError("'\(tenderd)' is not executable. Pass --tenderd-path.")
                }
                if mode.system {
                    try await installSystem(tenderd: tenderd)
                } else {
                    try await installDev(tenderd: tenderd)
                }
            }

            private func installDev(tenderd: String) async throws {
                let environment = TenderEnvironment.development
                let files = FileManager.default
                try files.createDirectory(at: environment.logsDirectory, withIntermediateDirectories: true)
                try files.createDirectory(at: environment.plistDirectory, withIntermediateDirectories: true)
                let plist = environment.plistPath(label: environment.agentLabel)
                try PlistRenderer().render(
                    label: environment.agentLabel,
                    programArguments: [tenderd, "--role", "worker", "--dev"],
                    stdoutPath: environment.logsDirectory.appending(path: "tenderd.out.log").path(percentEncoded: false),
                    stderrPath: environment.logsDirectory.appending(path: "tenderd.err.log").path(percentEncoded: false)
                ).write(to: plist, options: .atomic)
                try await Daemon.load(plist: plist, environment: environment)
                print("Installed \(environment.agentLabel) running \(tenderd)")
            }

            private func installSystem(tenderd: String) async throws {
                if !dryRun { try Daemon.requireRoot("install") }
                let plan = SystemInstallPlan()
                let environment = plan.environment
                let commands = try plan.commands(
                    users: SystemInstallPlan.parseIDs(try await Self.output("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])),
                    groups: SystemInstallPlan.parseIDs(try await Self.output("/usr/bin/dscl", [".", "-list", "/Groups", "PrimaryGroupID"])),
                    tenderdSource: tenderd
                )
                let plist = environment.plistPath(label: environment.agentLabel)

                if dryRun {
                    commands.forEach { print($0) }
                    print("write \(plist.path(percentEncoded: false)) (root:wheel 644):")
                    print(String(decoding: try plan.renderDaemonPlist(), as: UTF8.self))
                    print("launchctl bootout system/\(environment.agentLabel)")
                    print("launchctl enable system/\(environment.agentLabel)")
                    print("launchctl bootstrap system \(plist.path(percentEncoded: false))")
                    return
                }

                for command in commands {
                    let result = try await ProcessLaunchctlRunner.runTool(executable: command.executable, arguments: command.arguments)
                    guard result.exitCode == 0 else {
                        throw SystemInstallError.commandFailed(command.description, result.stderr)
                    }
                }
                try plan.renderDaemonPlist().write(to: plist, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                    ofItemAtPath: plist.path(percentEncoded: false))
                try await Daemon.load(plist: plist, environment: environment)
                print("Installed \(environment.agentLabel) running \(plan.installedDaemon.path(percentEncoded: false))")
            }

            private static func output(_ executable: String, _ arguments: [String]) async throws -> String {
                let result = try await ProcessLaunchctlRunner.runTool(executable: executable, arguments: arguments)
                guard result.exitCode == 0 else {
                    throw SystemInstallError.commandFailed(([executable] + arguments).joined(separator: " "), result.stderr)
                }
                return result.stdout
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
                abstract: "Remove tenderd's launchd job. Managed services keep running, and data and the service account stay."
            )

            @OptionGroup var mode: Mode

            func run() async throws {
                if mode.system { try Daemon.requireRoot("uninstall") }
                let environment = mode.environment
                let label = environment.agentLabel
                try await Daemon.bootoutAndWait(Launchctl(domain: .forEnvironment(environment)), label: label)
                try? FileManager.default.removeItem(at: environment.plistPath(label: label))
                print("Uninstalled \(label)")
            }
        }
    }
}
