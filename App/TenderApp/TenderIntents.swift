import AppIntents
import Foundation
import TenderClient
import TenderCore

/// Shortcuts, Siri and Spotlight actions. They use the app's active connection, so a
/// read-only token can check status and search logs, and starting or stopping needs `write`.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    var message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

private func connectedClient() throws -> TenderClient {
    guard let saved = try ClusterModel.makeStore().activeCredentials() else {
        throw IntentFailure(message: "Tender isn't connected to a head. Connect in its settings first.")
    }
    let context = saved.connection.context
    return TenderClient(head: context.head, caPEM: context.caPEM, token: saved.token, timeout: .seconds(30))
}

/// Runs a call, turning errors into text that Shortcuts and Siri can show.
private func withClient<T: Sendable>(_ call: @Sendable (TenderClient) async throws -> T) async throws -> T {
    let client = try connectedClient()
    do {
        return try await call(client)
    } catch {
        throw IntentFailure(message: "\(error)")
    }
}

// MARK: - Services

struct ServiceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    static let defaultQuery = ServiceQuery()

    var id: String
    var service: String
    var node: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(service)", subtitle: "on \(node)")
    }
}

struct ServiceQuery: EntityQuery {
    /// One entry per service per node, however many instances it runs.
    private func all() async throws -> [ServiceEntity] {
        let processes = try await withClient { try await $0.list().processes }
        var seen = Set<String>()
        return processes.compactMap { process in
            let node = process.node.rawValue
            let id = "\(process.service)@\(node)"
            guard seen.insert(id).inserted else { return nil }
            return ServiceEntity(id: id, service: process.service, node: node)
        }
        .sorted { $0.id < $1.id }
    }

    func entities(for identifiers: [String]) async throws -> [ServiceEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServiceEntity] {
        try await all()
    }
}

struct StartServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Service"
    static let description = IntentDescription("Starts a service on its node.")

    @Parameter(title: "Service") var service: ServiceEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$service)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (name, node) = (service.service, service.node)
        _ = try await withClient { try await $0.start(service: name, node: node) }
        return .result(dialog: "Started \(name) on \(node).")
    }
}

/// Stopping and restarting interrupt a running service, so both ask first.
struct StopServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Service"
    static let description = IntentDescription("Stops a service on its node, after asking you to confirm.")

    @Parameter(title: "Service") var service: ServiceEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$service)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (name, node) = (service.service, service.node)
        try await requestConfirmation(actionName: .turnOff, dialog: "Stop \(name) on \(node)?")
        _ = try await withClient { try await $0.stop(service: name, node: node) }
        return .result(dialog: "Stopped \(name) on \(node).")
    }
}

struct RestartServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Service"
    static let description = IntentDescription("Restarts a service on its node, after asking you to confirm.")

    @Parameter(title: "Service") var service: ServiceEntity

    static var parameterSummary: some ParameterSummary { Summary("Restart \(\.$service)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (name, node) = (service.service, service.node)
        try await requestConfirmation(actionName: .go, dialog: "Restart \(name) on \(node)?")
        _ = try await withClient { try await $0.restart(service: name, node: node) }
        return .result(dialog: "Restarted \(name) on \(node).")
    }
}

// MARK: - Reading

struct ClusterStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Cluster Status"
    static let description = IntentDescription("Says whether the cluster is healthy, and names what isn't.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let (nodes, processes) = try await withClient { client in
            async let nodes = client.nodes()
            async let processes = client.list()
            return try await (nodes, processes)
        }
        let down = nodes.nodes.filter { !$0.up }.map { "\($0.info.id.rawValue) is down" }
        let crashed = processes.processes.filter { $0.state == .crashed }
            .map { "\($0.service) crashed on \($0.node.rawValue)" }
        let problems = down + crashed
        let summary = ClusterHealth(nodes: nodes, processes: processes).summary
        // Spoken by Siri as well as shown, so the list stays short.
        let shown = problems.prefix(5) + (problems.count > 5 ? ["and \(problems.count - 5) more"] : [])
        let text = shown.isEmpty ? summary : "\(summary): \(shown.joined(separator: "; "))"
        return .result(value: text, dialog: "\(text)")
    }
}

struct SearchLogsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Tender Logs"
    static let description = IntentDescription("Finds recent log lines from across the cluster, newest 50 at most.")

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Service") var service: String?
    @Parameter(title: "Past hours", default: 1, inclusiveRange: (1, 168)) var hours: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search logs for \(\.$text) in the past \(\.$hours) hours") { \.$service }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let query = LogQuery(service: service, since: Date(timeIntervalSinceNow: -Double(hours) * 3600),
                             text: text, limit: 50)
        let result = try await withClient { try await $0.searchLogs(query) }
        let lines = result.entries.map { "\($0.node.rawValue) \($0.service): \($0.line)" }
        return .result(value: lines, dialog: "Found \(lines.count) matching lines.")
    }
}

// MARK: - Shortcuts app and Siri

struct TenderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ClusterStatusIntent(),
                    phrases: ["Get cluster status in \(.applicationName)",
                              "How is my \(.applicationName) cluster"],
                    shortTitle: "Cluster Status", systemImageName: "checkmark.circle")
        AppShortcut(intent: RestartServiceIntent(),
                    phrases: ["Restart a service in \(.applicationName)"],
                    shortTitle: "Restart Service", systemImageName: "arrow.clockwise")
        AppShortcut(intent: StartServiceIntent(),
                    phrases: ["Start a service in \(.applicationName)"],
                    shortTitle: "Start Service", systemImageName: "play")
        AppShortcut(intent: StopServiceIntent(),
                    phrases: ["Stop a service in \(.applicationName)"],
                    shortTitle: "Stop Service", systemImageName: "stop")
        AppShortcut(intent: SearchLogsIntent(),
                    phrases: ["Search logs in \(.applicationName)"],
                    shortTitle: "Search Logs", systemImageName: "magnifyingglass")
    }
}
