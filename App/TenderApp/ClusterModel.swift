import Foundation
import Observation
import TenderClient
import TenderCore

/// The app's view of the cluster, polled from the head every 5 seconds.
@MainActor
@Observable
final class ClusterModel {
    private(set) var health: ClusterHealth = .notConfigured
    private(set) var nodes: [NodeSummary] = []
    private(set) var processes: [InstanceStatus] = []
    private(set) var history = NodeHistory()
    private(set) var head: String?
    private(set) var connections = ConnectionList()
    private(set) var connectionStatus: [UUID: ConnectionStatus] = [:]
    /// Why the active connection couldn't be used, such as a token saved by another build.
    private(set) var savedConnectionError: String?
    var actionError: String?

    private var client: TenderClient?
    private let store: ConnectionStore
    private var polling: Task<Void, Never>?

    enum ConnectionStatus: Equatable {
        case checking, reachable, unreachable(String)
    }

    /// Where the app keeps its heads and tokens. The intents read the same place.
    nonisolated static func makeStore() -> ConnectionStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConnectionStore(
            directory: home.appending(path: "Library/Application Support/TenderApp"),
            secrets: KeychainSecretStore(
                keychainPath: home.appending(path: "Library/Keychains/login.keychain-db").path(percentEncoded: false),
                service: "com.olympsis.tender.app"))
    }

    init() {
        store = Self.makeStore()
        useActiveConnection()
        startPolling()
    }

    #if DEBUG
    /// Fixed data for Xcode previews: no polling, no Keychain, no network.
    init(previewHealth: ClusterHealth, nodes: [NodeSummary], processes: [InstanceStatus]) {
        store = ConnectionStore(directory: URL(filePath: "/dev/null"),
                                secrets: FileSecretStore(directory: URL(filePath: "/dev/null")))
        health = previewHealth
        self.nodes = nodes
        self.processes = processes
        history = .preview(nodes)
        head = nodes.isEmpty ? nil : "mac-1:7071"
    }
    #endif

    /// The name given to the active connection. An unnamed one has only its address, which
    /// tells you less than the node's name and wouldn't fit in the menu bar.
    var activeConnectionName: String? {
        connections.active.flatMap { $0.name == $0.context.head ? nil : $0.name }
    }

    /// The active cluster's head, once it has reported its role.
    var headNodeName: String? {
        nodes.first { $0.info.isHead }?.info.id.rawValue
    }

    var problems: [InstanceStatus] { processes.filter { $0.state == .crashed || $0.state == .unknown } }

    /// Fetches the CA and pins it, using the fingerprint in the token, then makes the
    /// new connection active.
    func addConnection(name: String, head: String, token: String) async throws {
        let caPEM = try await ClientPinning.fetchCA(head: head, credential: token)
        _ = try await TenderClient(head: head, caPEM: caPEM, token: token).nodes()
        try store.add(name: name, context: ClientContext(head: head, caPEM: caPEM), token: token)
        useActiveConnection()
        await refresh()
        await checkConnections()
    }

    func switchToConnection(_ id: UUID) async {
        do {
            try store.activate(id: id)
        } catch {
            savedConnectionError = "\(error)"
        }
        useActiveConnection()
        await refresh()
    }

    func removeConnection(_ id: UUID) async {
        do {
            try store.remove(id: id)
        } catch {
            savedConnectionError = "\(error)"
        }
        connectionStatus[id] = nil
        useActiveConnection()
        await refresh()
    }

    /// Points the app at the active connection and drops what the last one reported.
    private func useActiveConnection() {
        client = nil
        head = nil
        nodes = []
        processes = []
        history = NodeHistory()
        health = .notConfigured
        savedConnectionError = nil
        do {
            connections = try store.load()
            if let saved = try store.activeCredentials() {
                let context = saved.connection.context
                head = context.head
                client = TenderClient(head: context.head, caPEM: context.caPEM, token: saved.token)
            }
        } catch {
            savedConnectionError = "\(error)"
        }
    }

    /// Checks every saved connection once, for the list in Settings.
    func checkConnections() async {
        let store = store
        let saved = connections.connections
        for connection in saved { connectionStatus[connection.id] = .checking }
        await withTaskGroup(of: (UUID, ConnectionStatus).self) { group in
            for connection in saved {
                group.addTask {
                    do {
                        let client = TenderClient(head: connection.context.head, caPEM: connection.context.caPEM,
                                                  token: try store.token(for: connection), timeout: .seconds(5))
                        _ = try await client.nodes()
                        return (connection.id, .reachable)
                    } catch {
                        return (connection.id, .unreachable("\(error)"))
                    }
                }
            }
            for await (id, status) in group where connections.connections.contains(where: { $0.id == id }) {
                connectionStatus[id] = status
            }
        }
    }

    private func startPolling() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        guard let client else {
            health = savedConnectionError.map { .unreachable($0) } ?? .notConfigured
            return
        }
        let requested = connections.activeID
        do {
            async let fetchedNodes = client.nodes()
            async let fetchedProcesses = client.list()
            let (nodeList, processList) = try await (fetchedNodes, fetchedProcesses)
            // The active connection may have changed during the wait.
            guard requested == connections.activeID else { return }
            nodes = nodeList.nodes
            processes = processList.processes
            history.record(nodeList.nodes)
            health = ClusterHealth(nodes: nodeList, processes: processList)
        } catch {
            guard requested == connections.activeID else { return }
            health = .unreachable("\(error)")
        }
    }

    /// Fills in a node's history from the head, for the window about to be shown. A head
    /// without history (older tenderd) leaves what the app recorded itself.
    func loadHistory(nodeID: String, window: TimeInterval) async {
        guard let client else { return }
        let requested = connections.activeID
        guard let fetched = try? await client.nodeHistory(node: nodeID, since: Date().addingTimeInterval(-window)),
              requested == connections.activeID else { return }
        history.seed(nodeID, with: fetched.points)
    }

    func searchLogs(_ query: LogQuery) async throws -> LogSearchResult? {
        try await client?.searchLogs(query)
    }

    func followLogs(_ query: LogQuery) -> AsyncThrowingStream<LogEntry, Error>? {
        client?.followClusterLogs(query)
    }

    func releases(service: String) async throws -> ClusterReleases? {
        try await client?.clusterReleases(service: service)
    }

    func deploy(service: String, version: String) async throws -> String {
        guard let client else { return "Not connected." }
        let response = try await client.deploy(service: service, version: version)
        return response.outcomes.map { "\($0.node): \($0.sha12 ?? $0.error ?? "?")" }.joined(separator: "\n")
    }

    func rollback(service: String, to sha12: String, node: String) async throws -> String {
        guard let client else { return "Not connected." }
        _ = try await client.rollback(service: service, to: sha12, node: node)
        return "\(node): rolled back to \(sha12)"
    }

    enum Action { case start, stop, restart }

    func perform(_ action: Action, on process: InstanceStatus) async {
        guard let client else { return }
        let node = process.node.rawValue
        do {
            switch action {
            case .start: _ = try await client.start(service: process.service, node: node)
            case .stop: _ = try await client.stop(service: process.service, node: node)
            case .restart: _ = try await client.restart(service: process.service, node: node)
            }
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
        await refresh()
    }
}
