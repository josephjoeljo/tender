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

            @Option(help: "head or worker.")
            var role = "worker"

            @Option(help: "With --dev: address to listen on.")
            var listen = "127.0.0.1"

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
                    programArguments: [tenderd, "run", "--role", role, "--dev", "--identity-mode", "warn", "--listen", listen],
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
                    print(String(decoding: try plan.renderDaemonPlist(role: role), as: UTF8.self))
                    print("launchctl bootout system/\(environment.agentLabel)")
                    print("launchctl enable system/\(environment.agentLabel)")
                    print("launchctl bootstrap system \(plist.path(percentEncoded: false))")
                    return
                }

                // Keychain items trust the binary that wrote them, so the old daemon hands
                // them to the new one. The file is 0600 in a root-only directory.
                let handoff = environment.runDirectory.appending(path: "secrets-handoff.json").path(percentEncoded: false)
                let installed = plan.installedDaemon.path(percentEncoded: false)
                if FileManager.default.fileExists(atPath: handoff) {
                    throw SystemInstallError.unfinishedUpgrade(daemon: installed, handoff: handoff)
                }
                let upgrading = FileManager.default.isExecutableFile(atPath: installed)
                let previousDaemon = Self.fileNumber(installed)
                if upgrading {
                    let export = try await ProcessLaunchctlRunner.runTool(executable: installed, arguments: ["secrets-export", "--to", handoff])
                    guard export.exitCode == 0 else {
                        throw SystemInstallError.commandFailed("tenderd secrets-export", export.stderr)
                    }
                }
                do {
                    for command in commands {
                        let result = try await ProcessLaunchctlRunner.runTool(executable: command.executable, arguments: command.arguments)
                        guard result.exitCode == 0 else {
                            throw SystemInstallError.commandFailed(command.description, result.stderr)
                        }
                    }
                } catch {
                    // The same file means the old daemon can still read the Keychain, so
                    // the copy isn't needed. A replaced file means it may be the only copy.
                    if upgrading, Self.fileNumber(installed) == previousDaemon {
                        try? FileManager.default.removeItem(atPath: handoff)
                    }
                    throw error
                }
                if upgrading {
                    // The file is kept on failure: an import can stop after deleting items.
                    guard let restore = try? await ProcessLaunchctlRunner.runTool(executable: installed, arguments: ["secrets-import", "--from", handoff]),
                          restore.exitCode == 0 else {
                        throw SystemInstallError.unfinishedUpgrade(daemon: installed, handoff: handoff)
                    }
                }
                try plan.renderDaemonPlist(role: role).write(to: plist, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                    ofItemAtPath: plist.path(percentEncoded: false))
                try await Daemon.load(plist: plist, environment: environment)
                print("Installed \(environment.agentLabel) running \(plan.installedDaemon.path(percentEncoded: false))")
            }

            private static func fileNumber(_ path: String) -> Int? {
                (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
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
