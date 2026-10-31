import Foundation

public enum TenderVersion {
    public static let current = "0.1.0"
}

/// Stable identifier for a machine in the cluster (e.g. "mac-2").
public struct NodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Where a service's binary comes from.
public enum ProgramSource: Codable, Sendable, Equatable {
    /// An absolute path used as is.
    case executable(String)
    /// A release copied to `releases/<service>/<sha12>/`.
    case release(sha12: String)
}

/// Log files of a job Tender did not create (adopted jobs).
public struct LogPaths: Codable, Sendable, Equatable {
    public var stdout: String?
    public var stderr: String?

    public init(stdout: String? = nil, stderr: String? = nil) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// What the user asked Tender to run.
public struct ServiceSpec: Codable, Sendable, Equatable {
    public static let defaultUser = "_tender"

    public var name: String
    public var program: ProgramSource
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var instances: Int
    public var node: NodeID?
    /// Account the process runs as. launchd ignores it in the gui domain (dev mode).
    public var user: String
    public var logPaths: LogPaths?

    public init(
        name: String,
        program: ProgramSource,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        instances: Int = 1,
        node: NodeID? = nil,
        user: String = ServiceSpec.defaultUser,
        logPaths: LogPaths? = nil
    ) {
        self.name = name
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.instances = instances
        self.node = node
        self.user = user
        self.logPaths = logPaths
    }

    /// Service names end up in launchd labels and file paths, so only a safe
    /// alphabet is allowed. Dots are excluded: they separate label components.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name.first != "-" else { return false }
        return name.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
            default: false
            }
        }
    }
}

public enum InstanceState: String, Codable, Sendable {
    case running, stopped, crashed, starting, unknown
}

/// What a worker observed about one running instance.
public struct InstanceStatus: Codable, Sendable, Equatable {
    public var service: String
    public var instance: Int
    public var node: NodeID
    public var state: InstanceState
    public var pid: Int32?
    public var lastExitCode: Int32?
    /// Seconds since the current process started.
    public var uptime: TimeInterval?
    /// launchd runs since the job was loaded, minus the first one.
    public var restarts: Int
    /// sha12 of the release this instance runs, when it runs from one.
    public var release: String?
    /// CPU usage in percent of one core.
    public var cpu: Double?
    /// Resident set size in bytes.
    public var rss: UInt64?

    public init(service: String, instance: Int, node: NodeID, state: InstanceState,
                pid: Int32? = nil, lastExitCode: Int32? = nil, uptime: TimeInterval? = nil,
                restarts: Int = 0, release: String? = nil, cpu: Double? = nil, rss: UInt64? = nil) {
        self.service = service
        self.instance = instance
        self.node = node
        self.state = state
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.uptime = uptime
        self.restarts = restarts
        self.release = release
        self.cpu = cpu
        self.rss = rss
    }
}

/// A binary copied into the releases directory.
public struct Release: Codable, Sendable, Equatable {
    public var service: String
    public var sha12: String
    public var path: String
    public var createdAt: Date

    public init(service: String, sha12: String, path: String, createdAt: Date) {
        self.service = service
        self.sha12 = sha12
        self.path = path
        self.createdAt = createdAt
    }
}

/// Response of the process endpoints.
public struct ProcessList: Codable, Sendable, Equatable {
    public var processes: [InstanceStatus]
    /// Labels with Tender's prefix that aren't in the desired state.
    public var orphans: [String]

    public init(processes: [InstanceStatus], orphans: [String] = []) {
        self.processes = processes
        self.orphans = orphans
    }
}

/// Body of every non-2xx API response.
public struct APIErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
