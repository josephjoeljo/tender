import Foundation
import TenderCore

/// One external command of a system install, so that the same plan can be shown
/// by `--dry-run`, checked by tests and executed by `tender daemon install --system`.
public struct InstallCommand: Sendable, Equatable, CustomStringConvertible {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var description: String {
        ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Everything `tender daemon install --system` does before loading the daemon.
public struct SystemInstallPlan: Sendable {
    public static let serviceUser = ServiceSpec.defaultUser
    /// Hidden system accounts conventionally sit below 500.
    public static let idRange = 400..<500

    public let environment: TenderEnvironment

    public init(environment: TenderEnvironment = .production) {
        self.environment = environment
    }

    /// Where the daemon runs from: a root-owned copy. A root daemon must not run
    /// from a path its user can write to, such as a build directory.
    public var installedDaemon: URL { environment.root.appending(path: "libexec/tenderd") }

    /// Parses `dscl . -list /Users UniqueID` or `/Groups PrimaryGroupID`: `<name> <id>` rows.
    public static func parseIDs(_ output: String) -> [String: Int] {
        var ids: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count >= 2, let id = Int(columns[columns.count - 1]) {
                ids[String(columns[0])] = id
            }
        }
        return ids
    }

    /// An id free as both a uid and a gid, so that user and group can match.
    public static func freeID(users: [String: Int], groups: [String: Int]) -> Int? {
        let taken = Set(users.values).union(groups.values)
        return idRange.first { !taken.contains($0) }
    }

    /// Commands that create what's missing. Safe to run again on an installed Mac.
    public func commands(users: [String: Int], groups: [String: Int], tenderdSource: String) throws -> [InstallCommand] {
        let name = Self.serviceUser
        var commands: [InstallCommand] = []

        let groupID: Int
        if let existing = groups[name] {
            groupID = existing
        } else {
            guard let free = Self.freeID(users: users, groups: groups) else { throw SystemInstallError.noFreeID }
            groupID = free
            let path = "/Groups/\(name)"
            commands += [
                dscl("-create", path),
                dscl("-create", path, "PrimaryGroupID", String(groupID)),
                dscl("-create", path, "RealName", "Tender Services"),
                dscl("-create", path, "Password", "*"),
            ]
        }
        if users[name] == nil {
            let taken = Set(users.values).union(groups.values).subtracting([groupID])
            let uid = users.values.contains(groupID) ? Self.idRange.first { !taken.contains($0) && $0 != groupID } : groupID
            guard let uid else { throw SystemInstallError.noFreeID }
            let path = "/Users/\(name)"
            commands += [
                dscl("-create", path),
                dscl("-create", path, "UniqueID", String(uid)),
                dscl("-create", path, "PrimaryGroupID", String(groupID)),
                dscl("-create", path, "UserShell", "/usr/bin/false"),
                dscl("-create", path, "NFSHomeDirectory", "/var/empty"),
                dscl("-create", path, "RealName", "Tender Services"),
                dscl("-create", path, "Password", "*"),
                dscl("-create", path, "IsHidden", "1"),
            ]
        }

        for directory in [environment.root, environment.binDirectory, environment.releasesDirectory,
                          environment.spoolDirectory, environment.root.appending(path: "libexec"),
                          environment.logsDirectory, environment.configDirectory] {
            commands.append(directoryCommand(directory, mode: "755"))
        }
        commands.append(directoryCommand(environment.runDirectory, mode: "700"))

        // -S replaces the file atomically: a running binary is never overwritten in place.
        commands.append(InstallCommand("/usr/bin/install", [
            "-S", "-o", "root", "-g", "wheel", "-m", "755",
            tenderdSource, installedDaemon.path(percentEncoded: false),
        ]))
        return commands
    }

    public func renderDaemonPlist(role: String = "worker") throws -> Data {
        try PlistRenderer().render(
            label: environment.agentLabel,
            programArguments: [installedDaemon.path(percentEncoded: false), "run", "--role", role],
            stdoutPath: environment.logsDirectory.appending(path: "tenderd.out.log").path(percentEncoded: false),
            stderrPath: environment.logsDirectory.appending(path: "tenderd.err.log").path(percentEncoded: false),
            // tenderd exits when Tailscale never comes up; launchd's default (10s) would be
            // tolerable, but stating it keeps a restart loop paced.
            throttleInterval: Self.daemonThrottleInterval
        )
    }

    /// Seconds launchd waits between starts of tenderd.
    public static let daemonThrottleInterval = 15

    private func dscl(_ arguments: String...) -> InstallCommand {
        InstallCommand("/usr/bin/dscl", ["."] + arguments)
    }

    private func directoryCommand(_ url: URL, mode: String) -> InstallCommand {
        InstallCommand("/usr/bin/install", ["-d", "-o", "root", "-g", "wheel", "-m", mode, url.path(percentEncoded: false)])
    }
}

public enum SystemInstallError: Error, CustomStringConvertible {
    case noFreeID
    case commandFailed(String, String)
    case unfinishedUpgrade(daemon: String, handoff: String)

    public var description: String {
        switch self {
        case .noFreeID: "No free id between 400 and 499 for the \(SystemInstallPlan.serviceUser) account."
        case .commandFailed(let command, let message): "`\(command)` failed: \(message)"
        case .unfinishedUpgrade(let daemon, let handoff):
            "An upgrade didn't finish, and \(handoff) may hold the only copy of this node's secrets, including the CA key. "
                + "Don't delete it. Run `sudo \(daemon) secrets-import --from \(handoff)`, then install again."
        }
    }
}
