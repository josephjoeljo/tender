import TenderCore

// Placeholder until milestone 2, when these become protobuf/gRPC definitions
// for the head <-> worker stream.

public enum AgentCommand: Codable, Sendable {
    case start(ServiceSpec)
    case stop(service: String)
    case restart(service: String)
    case delete(service: String)
}

public enum AgentEvent: Codable, Sendable {
    case heartbeat(node: NodeID)
    case status([InstanceStatus])
}
