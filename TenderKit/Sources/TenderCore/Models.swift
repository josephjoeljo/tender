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

/// What a service is, so people can tell processes apart at a glance.
public enum ProcessKind: String, Codable, Sendable, CaseIterable {
    case server, gameServer = "game-server", database, cache, queue, worker, scheduler, proxy, model, other

    /// A kind from a newer tenderd decodes as `.other` instead of failing the whole list.
    public init(from decoder: Decoder) throws {
        self = ProcessKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    /// A best guess from a service name or launchd label, for services started without `--kind`.
    public static func guess(from name: String) -> ProcessKind {
        let name = name.lowercased()
        let hints: [(ProcessKind, [String])] = [
            (.database, ["mongo", "postgres", "mysql", "mariadb", "sqlite", "clickhouse", "cockroach", "db"]),
            (.cache, ["redis", "memcache", "valkey", "cache"]),
            (.queue, ["rabbit", "kafka", "nats", "queue", "mq"]),
            (.proxy, ["nginx", "caddy", "haproxy", "envoy", "traefik", "proxy", "gateway"]),
            (.gameServer, ["game", "minecraft", "valheim", "factorio"]),
            (.model, ["ollama", "llama", "mlx", "whisper", "inference", "model"]),
            (.scheduler, ["cron", "scheduler", "timer"]),
            (.worker, ["worker", "job", "consumer"]),
            (.server, ["api", "server", "web", "http", "app"]),
        ]
        return hints.first { _, needles in needles.contains { name.contains($0) } }?.0 ?? .other
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
    /// Nil means "guess from the name".
    public var kind: ProcessKind?
    /// Secrets written as files before launch: target path → reference, as inside
    /// `${secret:…}` (`GCP_KEY`, `shared/GCP_KEY`). For values that mustn't be in the environment.
    public var secretFiles: [String: String]

    public init(
        name: String,
        program: ProgramSource,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        instances: Int = 1,
        node: NodeID? = nil,
        user: String = ServiceSpec.defaultUser,
        logPaths: LogPaths? = nil,
        kind: ProcessKind? = nil,
        secretFiles: [String: String] = [:]
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
        self.kind = kind
        self.secretFiles = secretFiles
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

extension ServiceSpec {
    /// Specs saved before a field existed still decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            program: try container.decode(ProgramSource.self, forKey: .program),
            arguments: try container.decode([String].self, forKey: .arguments),
            environment: try container.decode([String: String].self, forKey: .environment),
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            instances: try container.decode(Int.self, forKey: .instances),
            node: try container.decodeIfPresent(NodeID.self, forKey: .node),
            user: try container.decode(String.self, forKey: .user),
            logPaths: try container.decodeIfPresent(LogPaths.self, forKey: .logPaths),
            kind: try container.decodeIfPresent(ProcessKind.self, forKey: .kind),
            secretFiles: try container.decodeIfPresent([String: String].self, forKey: .secretFiles) ?? [:]
        )
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
    /// CPU time of the current process, in seconds.
    public var cpuSeconds: Double?
    /// A job Tender manages but didn't create. `service` is then its launchd label.
    public var adopted: Bool
    /// Detailed resource use. Nil from nodes running an older tenderd.
    public var stats: ProcessStats?
    /// Nil from nodes running an older tenderd.
    public var kind: ProcessKind?

    public init(service: String, instance: Int, node: NodeID, state: InstanceState,
                pid: Int32? = nil, lastExitCode: Int32? = nil, uptime: TimeInterval? = nil,
                restarts: Int = 0, release: String? = nil, cpu: Double? = nil, rss: UInt64? = nil,
                cpuSeconds: Double? = nil, adopted: Bool = false, stats: ProcessStats? = nil,
                kind: ProcessKind? = nil) {
        self.kind = kind
        self.stats = stats
        self.cpuSeconds = cpuSeconds
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
        self.adopted = adopted
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
    /// Nodes whose processes couldn't be read, so the list may be incomplete.
    public var unreachableNodes: [String]

    public init(processes: [InstanceStatus], orphans: [String] = [], unreachableNodes: [String] = []) {
        self.processes = processes
        self.orphans = orphans
        self.unreachableNodes = unreachableNodes
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

/// One line of a process's output.
public struct LogLine: Codable, Sendable, Equatable {
    public enum Stream: String, Codable, Sendable { case out, err }

    public var service: String
    public var instance: Int
    public var stream: Stream
    public var text: String

    public init(service: String, instance: Int, stream: Stream, text: String) {
        self.service = service
        self.instance = instance
        self.stream = stream
        self.text = text
    }
}

public struct LogResponse: Codable, Sendable, Equatable {
    public var lines: [LogLine]
    public init(lines: [LogLine]) { self.lines = lines }
}

public struct ReleaseList: Codable, Sendable, Equatable {
    /// Newest first.
    public var releases: [Release]
    /// sha12 of the release the service runs, if any.
    public var current: String?

    public init(releases: [Release], current: String?) {
        self.releases = releases
        self.current = current
    }
}

public struct RollbackRequest: Codable, Sendable, Equatable {
    public var to: String?
    public init(to: String? = nil) { self.to = to }
}

/// A launchd job Tender manages but didn't create.
public struct AdoptedJob: Codable, Sendable, Equatable {
    public var label: String
    public var domain: String
    public var plistPath: String?
    public var stdoutPath: String?
    public var stderrPath: String?
    /// The `--log-path` (or `log_path:`) it was adopted with. Kept apart from `stdoutPath`
    /// so that export and apply know it without asking launchd, which forgets a stopped job.
    public var logPath: String?

    public init(label: String, domain: String, plistPath: String?, stdoutPath: String?, stderrPath: String?, logPath: String? = nil) {
        self.label = label
        self.domain = domain
        self.plistPath = plistPath
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.logPath = logPath
    }
}

public struct AdoptRequest: Codable, Sendable, Equatable {
    public var label: String
    /// Overrides the job's own `StandardOutPath`/`StandardErrorPath`.
    public var logPath: String?

    public init(label: String, logPath: String? = nil) {
        self.label = label
        self.logPath = logPath
    }
}
