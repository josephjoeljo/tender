import TenderCore

// Codable messages for head <-> worker traffic. In milestone 2 the node contract
// lives here too, as @Resolvable distributed protocols (NodeAgentProtocol,
// HeadRegistryProtocol) generic over DistributedActorSystem<any Codable>.
// No transport dependency. See docs/DESIGN.md §4.

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
