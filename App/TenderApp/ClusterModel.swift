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
