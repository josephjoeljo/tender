import Foundation
import Logging
import TenderCore

/// launchd domain to operate in.
public enum LaunchdDomain: Sendable {
    /// System-wide LaunchDaemons. Requires root.
    case system
    /// Per-user LaunchAgents (`gui/<uid>`). Used for development.
    case user(uid: uid_t)

    public var target: String {
        switch self {
        case .system: "system"
        case .user(let uid): "gui/\(uid)"
        }
    }

    public static var currentUser: LaunchdDomain { .user(uid: getuid()) }
}

/// Renders launchd property lists. Pure — no side effects, easy to unit test.
public struct PlistRenderer: Sendable {
    public init() {}

    public func render(
        label: String,
        programArguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        stdoutPath: String,
        stderrPath: String,
        keepAlive: Bool = true,
        runAtLoad: Bool = true
    ) throws -> Data {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "KeepAlive": keepAlive,
            "RunAtLoad": runAtLoad,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        if let workingDirectory { dict["WorkingDirectory"] = workingDirectory }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

/// Thin wrapper over `/bin/launchctl`. TODO(milestone 1): bootstrap, bootout,
/// kickstart, and parsing `launchctl print` into `InstanceStatus`.
public struct Launchctl: Sendable {
    public let domain: LaunchdDomain
    public init(domain: LaunchdDomain) { self.domain = domain }
}
