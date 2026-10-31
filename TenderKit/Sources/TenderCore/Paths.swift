import Foundation

/// Filesystem + launchd layout. `.production` uses system paths and the
/// launchd `system` domain (needs root); `.development` keeps everything under
/// the user's home and uses the `gui/<uid>` domain so Xcode can run it without sudo.
public struct TenderEnvironment: Sendable {
    public enum Mode: String, Sendable { case production, development }

    public let mode: Mode
    public let root: URL
    public let logsDirectory: URL
    public let plistDirectory: URL
    public let labelPrefix = "com.olympsis.tender"
    /// Every label below `<serviceLabelPrefix>.` belongs to a managed process.
    public let serviceLabelPrefix: String

    public init(
        mode: Mode,
        root: URL,
        logsDirectory: URL,
        plistDirectory: URL,
        serviceLabelPrefix: String = "com.olympsis.tender.svc"
    ) {
        self.mode = mode
        self.root = root
        self.logsDirectory = logsDirectory
        self.plistDirectory = plistDirectory
        self.serviceLabelPrefix = serviceLabelPrefix
    }

    public var binDirectory: URL { root.appending(path: "bin") }
    public var releasesDirectory: URL { root.appending(path: "releases") }
    public var spoolDirectory: URL { root.appending(path: "spool") }
    public var stateDB: URL { root.appending(path: "state.db") }
    /// Kept in its own 0700 directory so the socket is never reachable by other
    /// users, not even between bind() and chmod().
    public var runDirectory: URL { root.appending(path: "run") }
    public var socketPath: URL { runDirectory.appending(path: "tender.sock") }
    public var lockPath: URL { runDirectory.appending(path: "tenderd.lock") }
    public var agentLabel: String { "\(labelPrefix).agent" }

    public static let production = TenderEnvironment(
        mode: .production,
        root: URL(filePath: "/opt/tender"),
        logsDirectory: URL(filePath: "/var/log/tender"),
        plistDirectory: URL(filePath: "/Library/LaunchDaemons")
    )

    public static var development: TenderEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support/Tender")
        return TenderEnvironment(
            mode: .development,
            root: support,
            logsDirectory: support.appending(path: "logs"),
            plistDirectory: home.appending(path: "Library/LaunchAgents")
        )
    }

    public func serviceLabel(service: String, instance: Int) -> String {
        "\(serviceLabelPrefix).\(service).\(instance)"
    }

    public func plistPath(label: String) -> URL {
        plistDirectory.appending(path: "\(label).plist")
    }

    public func logDirectory(service: String) -> URL {
        logsDirectory.appending(path: service)
    }

    public func stdoutLog(service: String, instance: Int) -> URL {
        logDirectory(service: service).appending(path: "\(instance).out.log")
    }

    public func stderrLog(service: String, instance: Int) -> URL {
        logDirectory(service: service).appending(path: "\(instance).err.log")
    }

    public func releaseBinary(service: String, sha12: String) -> URL {
        releasesDirectory.appending(path: "\(service)/\(sha12)/\(service)")
    }
}
