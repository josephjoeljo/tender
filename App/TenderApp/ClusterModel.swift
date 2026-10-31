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
    private(set) var head: String?
    var actionError: String?

    private var client: TenderClient?
    private let store: ClientContextStore
    private var polling: Task<Void, Never>?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        store = ClientContextStore(
            directory: home.appending(path: "Library/Application Support/TenderApp"),
            secrets: KeychainSecretStore(
                keychainPath: home.appending(path: "Library/Keychains/login.keychain-db").path(percentEncoded: false),
                service: "com.olympsis.tender.app"))
        if let saved = try? store.load() {
            head = saved.context.head
            client = TenderClient(head: saved.context.head, caPEM: saved.context.caPEM, token: saved.token)
        }
        startPolling()
    }

    #if DEBUG
    /// Fixed data for Xcode previews: no polling, no Keychain, no network.
    init(previewHealth: ClusterHealth, nodes: [NodeSummary], processes: [InstanceStatus]) {
        store = ClientContextStore(directory: URL(filePath: "/dev/null"),
                                   secrets: FileSecretStore(directory: URL(filePath: "/dev/null")))
        health = previewHealth
        self.nodes = nodes
        self.processes = processes
        head = nodes.isEmpty ? nil : "mac-1:7071"
    }
    #endif

    var problems: [InstanceStatus] { processes.filter { $0.state == .crashed || $0.state == .unknown } }

    /// Fetches the CA and pins it, using the fingerprint in the token.
    func connect(head: String, token: String) async throws {
        let caPEM = try await ClientPinning.fetchCA(head: head, credential: token)
        let candidate = TenderClient(head: head, caPEM: caPEM, token: token)
        _ = try await candidate.nodes()
        try store.save(ClientContext(head: head, caPEM: caPEM), token: token)
        self.head = head
        client = candidate
        await refresh()
    }

    func disconnect() {
        try? store.clear()
        client = nil
        head = nil
        nodes = []
        processes = []
        health = .notConfigured
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
            health = .notConfigured
            return
        }
        do {
            async let fetchedNodes = client.nodes()
            async let fetchedProcesses = client.list()
            let (nodeList, processList) = try await (fetchedNodes, fetchedProcesses)
            nodes = nodeList.nodes
            processes = processList.processes
            health = ClusterHealth(nodes: nodeList, processes: processList)
        } catch {
            health = .unreachable("\(error)")
        }
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
