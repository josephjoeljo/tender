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

    public var binDirectory: URL { root.appending(path: "bin") }
    public var releasesDirectory: URL { root.appending(path: "releases") }
    public var spoolDirectory: URL { root.appending(path: "spool") }

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
        "\(labelPrefix).svc.\(service).\(instance)"
    }
}
