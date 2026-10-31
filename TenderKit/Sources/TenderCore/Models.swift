import Foundation

/// Stable identifier for a machine in the cluster (e.g. "mac-2").
public struct NodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What the user asked Tender to run.
public struct ServiceSpec: Codable, Sendable, Equatable {
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var instances: Int
    public var node: NodeID?

    public init(
        name: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        instances: Int = 1,
        node: NodeID? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.instances = instances
        self.node = node
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

    public init(service: String, instance: Int, node: NodeID, state: InstanceState,
                pid: Int32? = nil, lastExitCode: Int32? = nil) {
        self.service = service
        self.instance = instance
        self.node = node
        self.state = state
        self.pid = pid
        self.lastExitCode = lastExitCode
    }
}
