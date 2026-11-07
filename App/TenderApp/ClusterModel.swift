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
    /// How long the head keeps stats history. Nil until loaded, and on heads from before the setting.
    private(set) var historyRetention: HistoryRetention?
    /// Why it couldn't be read or changed, such as a read-only token.
    private(set) var historyRetentionError: String?
    /// Every node's service specs, for the process inspector's config. Nil until loaded.
    private(set) var specs: SpecList?
    /// Why the specs couldn't be read, such as a read-only token.
    private(set) var specsError: String?
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
        #if os(iOS)
        return ConnectionStore(directory: .applicationSupportDirectory.appending(path: "TenderApp"),
                               secrets: KeychainItemStore(service: "com.olympsis.tender.app"))
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConnectionStore(
            directory: home.appending(path: "Library/Application Support/TenderApp"),
            secrets: KeychainSecretStore(
                keychainPath: home.appending(path: "Library/Keychains/login.keychain-db").path(percentEncoded: false),
                service: "com.olympsis.tender.app"))
        #endif
    }

    init() {
        store = Self.makeStore()
        useActiveConnection()
        startPolling()
    }

    #if DEBUG
    /// Set by the preview initializer, so calls that would reach a head return sample data.
    private(set) var isPreview = false

    /// Fixed data for Xcode previews: no polling, no Keychain, no network.
    init(previewHealth: ClusterHealth, nodes: [NodeSummary], processes: [InstanceStatus]) {
        store = ConnectionStore(directory: URL(filePath: "/dev/null"),
                                secrets: FileSecretStore(directory: URL(filePath: "/dev/null")))
        health = previewHealth
        self.nodes = nodes
        self.processes = processes
        history = .preview(nodes)
        head = nodes.isEmpty ? nil : "mac-1:7071"
        specs = .preview(processes)
        historyRetention = HistoryRetention()
        isPreview = true
    }
    #endif

    /// The name given to the active connection. An unnamed one has only its address, which
    /// tells you less than the node's name and wouldn't fit in the menu bar.
    var activeConnectionName: String? {
        connections.active.flatMap { $0.name == $0.context.head ? nil : $0.name }
    }

    /// The active cluster's head, once it has reported its role.
    var headNodeName: String? {
        nodes.first { $0.info.isHead }?.info.displayName
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
        specs = nil
        specsError = nil
        historyRetention = nil
        historyRetentionError = nil
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
            // Sorted here too: a head running an older tenderd sorts by ID.
            nodes = nodeList.nodes.headFirst()
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

    /// Reads the head's history retention, once per connection unless `force`. A head
    /// from before the setting leaves it nil, so every window stays on offer.
    func loadHistoryRetention(force: Bool = false) async {
        guard let client, force || historyRetention == nil else { return }
        let requested = connections.activeID
        do {
            let retention = try await client.historyRetention()
            guard requested == connections.activeID else { return }
            historyRetention = retention
            historyRetentionError = nil
        } catch let error as TenderClientError where error.code == "http_404" {
            historyRetentionError = "This head's tenderd keeps history for a fixed 6 months. Update it to change that."
        } catch {
            historyRetentionError = "\(error)"
        }
    }

    /// Changes the head's retention. Needs a write token; the reason it failed is left in
    /// `historyRetentionError`.
    func setHistoryRetention(_ update: HistoryRetentionUpdate) async {
        #if DEBUG
        if isPreview {
            historyRetention?.nodeDays = update.nodeDays ?? historyRetention?.nodeDays ?? HistoryRetention.defaultDays
            historyRetention?.processDays = update.processDays ?? historyRetention?.processDays ?? HistoryRetention.defaultDays
            return
        }
        #endif
        guard let client else { return }
        do {
            historyRetention = try await client.setHistoryRetention(update)
            historyRetentionError = nil
        } catch let error as TenderClientError where error.code == "forbidden" {
            historyRetentionError = "This connection's token is read-only. Changing retention needs a write token."
        } catch {
            historyRetentionError = "\(error)"
        }
    }

    /// One instance's history from the head, for the window about to be shown.
    func processHistory(of process: InstanceStatus, window: TimeInterval) async -> ProcessHistoryLoad {
        #if DEBUG
        if isPreview { return .points(ProcessStatsPoint.preview(process, window: window)) }
        #endif
        guard let client else { return .failed("Not connected to a head.") }
        do {
            let history = try await client.processHistory(service: process.service, node: process.node.rawValue,
                                                          instance: process.instance,
                                                          since: Date().addingTimeInterval(-window), limit: 400)
            return .points(history.points)
        } catch let error as TenderClientError where error.code == "http_404" {
            return .unsupported
        } catch {
            return .failed("\(error)")
        }
    }

    /// Reads every node's specs. Needs a write token, since specs can hold literal values
    /// from an `env_file`; with a read-only one this leaves the reason in `specsError`.
    func loadSpecs() async {
        guard let client else { return }
        let requested = connections.activeID
        do {
            let fetched = try await client.specs()
            guard requested == connections.activeID else { return }
            specs = fetched
            specsError = nil
        } catch {
            guard requested == connections.activeID else { return }
            specsError = "\(error)"
        }
    }

    /// The spec a process was started from, or nil for an adopted job or one not found.
    func spec(for process: InstanceStatus) -> ServiceSpec? {
        specs?.nodes.first { $0.node == process.node }?.services.first { $0.name == process.service }
    }

    /// The adopted-job entry for a process Tender didn't create.
    func adoptedItem(for process: InstanceStatus) -> AdoptedItem? {
        specs?.nodes.first { $0.node == process.node }?.adopted.first { $0.label == process.service }
    }

    /// The ports, open files and descriptor counts of a running process, read from its node.
    func descriptors(for process: InstanceStatus) async throws -> ProcessDescriptors? {
        #if DEBUG
        if isPreview { return .preview(process) }
        #endif
        return try await client?.descriptors(service: process.service, instance: process.instance, node: process.node.rawValue)
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
        return response.outcomes.map { "\(name(of: $0.node)): \($0.sha12 ?? $0.error ?? "?")" }.joined(separator: "\n")
    }

    func rollback(service: String, to sha12: String, node: String) async throws -> String {
        guard let client else { return "Not connected." }
        _ = try await client.rollback(service: service, to: sha12, node: node)
        return "\(name(of: NodeID(node))): rolled back to \(sha12)"
    }

    /// A node's hostname, or its ID when it hasn't reported one.
    func name(of node: NodeID) -> String {
        nodes.first { $0.info.id == node }?.info.displayName ?? node.rawValue
    }

    /// Deletes the node's records on the head. A node that is up needs `force`.
    func removeNode(_ node: NodeSummary, force: Bool) async {
        guard let client else { return }
        do {
            _ = try await client.removeNode(node.info.id.rawValue, force: force)
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
        await refresh()
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
