import SwiftUI
import TenderClient
import TenderCore

/// Full dashboard: nodes, processes, logs, releases.
struct DashboardView: View {
    let model: ClusterModel

    enum Section: String, CaseIterable, Identifiable {
        case nodes = "Nodes", processes = "Processes", logs = "Logs", releases = "Releases", settings = "Settings"
        var id: String { rawValue }
        static let pages: [Section] = [.nodes, .processes, .logs, .releases]
        var symbol: String {
            switch self {
            case .nodes: "desktopcomputer"
            case .processes: "gearshape.2"
            case .logs: "text.alignleft"
            case .releases: "shippingbox"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Section? = .nodes

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.pages) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
                SwiftUI.Section {
                    Label(Section.settings.rawValue, systemImage: Section.settings.symbol).tag(Section.settings)
                }
            }
            .font(.app(.body))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if selection == .settings {
                SettingsView(model: model, fixedWidth: false)
                    .navigationTitle("Settings")
            } else if model.head == nil {
                ContentUnavailableView("No head connected", systemImage: "leaf",
                                       description: Text("Add a head and token in Settings."))
            } else {
                switch selection ?? .nodes {
                case .nodes: NodesView(model: model)
                case .processes: ProcessesView(model: model)
                case .logs: LogsView(model: model)
                case .releases: ReleasesView(model: model)
                case .settings: EmptyView()
                }
            }
        }
    }
}

/// In the list, click a row to drop down its machine stats; the bento grid shows them all at once.
/// Either way, a node's chevron or card opens it on its own, with its history.
struct NodesView: View {
    let model: ClusterModel
    @State private var expanded: Set<String> = []
    @State private var addingNode = false
    @State private var path: [String] = []
    @AppStorage("nodesLayout") private var layout: NodesLayout = .list

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch layout {
                case .list:
                    List(model.nodes) { node in
                        ExpandableRow(isExpanded: expanded.contains(node.id), toggle: { expanded.toggle(node.id) }) {
                            NodeTrackRow(node: node, open: { path.append(node.id) })
                        } detail: {
                            NodeStatsPanel(node: node)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in RowLayout.textLeading }
                    }
                    .listStyle(.inset)
                case .bento:
                    NodesBentoView(nodes: model.nodes, open: { path.append($0.id) })
                }
            }
            .navigationTitle("Nodes")
            .toolbar {
                Picker("Layout", selection: $layout) {
                    ForEach(NodesLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show nodes as a list or as cards")
                Button("Add Node", systemImage: "plus") { addingNode = true }
                    .help("Add a Mac to this cluster")
            }
            .navigationDestination(for: String.self) { NodeDetailView(model: model, nodeID: $0) }
        }
        .sheet(isPresented: $addingNode) { AddNodeSheet(model: model) }
    }
}

extension NodeSummary: @retroactive Identifiable {
    public var id: String { info.id.rawValue }
}

extension InstanceStatus: @retroactive Identifiable {
    public var id: String { rowID }
}

/// Click a row to drop down the process's CPU, memory, storage, GPU, Neural Engine and energy use.
struct ProcessesView: View {
    let model: ClusterModel
    @State private var expanded: Set<String> = []

    var body: some View {
        let counts = Dictionary(model.processes.map { ("\($0.node.rawValue)/\($0.service)", 1) }, uniquingKeysWith: +)
        List(model.processes) { process in
            ExpandableRow(isExpanded: expanded.contains(process.id), toggle: { expanded.toggle(process.id) }) {
                ProcessTrackRow(process: process, model: model,
                                showsInstance: counts["\(process.node.rawValue)/\(process.service)", default: 0] > 1)
            } detail: {
                ProcessStatsPanel(process: process, node: model.nodes.first { $0.info.id == process.node })
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in RowLayout.textLeading }
        }
        .listStyle(.inset)
        .navigationTitle("Processes")
    }
}

/// Search plus live follow. Lines stay bounded so that a busy service can't grow the view forever.
struct LogsView: View {
    let model: ClusterModel
    private static let maxLines = 5_000

    @State private var text = ""
    @State private var service = ""
    @State private var node = ""
    @State private var stream = "all"
    @State private var window = 3600.0
    @State private var entries: [LogEntry] = []
    @State private var gaps: [LogGap] = []
    @State private var following = false
    @State private var error: String?
    @State private var follow: Task<Void, Never>?

    private var query: LogQuery {
        LogQuery(service: service.isEmpty ? nil : service, node: node.isEmpty ? nil : node,
                 stream: LogLine.Stream(rawValue: stream), since: Date().addingTimeInterval(-window),
                 text: text.isEmpty ? nil : text, limit: 1000)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $text).onSubmit(search)
                TextField("Service", text: $service).frame(width: 120).onSubmit(search)
                TextField("Node", text: $node).frame(width: 100).onSubmit(search)
                Picker("", selection: $stream) {
                    Text("All").tag("all")
                    Text("stdout").tag("out")
                    Text("stderr").tag("err")
                }
                .frame(width: 90)
                Picker("", selection: $window) {
                    Text("15 min").tag(900.0)
                    Text("1 hour").tag(3600.0)
                    Text("1 day").tag(86400.0)
                    Text("7 days").tag(7 * 86400.0)
                }
                .frame(width: 90)
                Button("Search", action: search)
                Toggle("Follow", isOn: $following).toggleStyle(.button)
            }
            .padding(8)
            Divider()
            if !gaps.isEmpty {
                Text(gaps.map { "\($0.node?.rawValue ?? "?") dropped \($0.droppedLines) lines" }.joined(separator: " · "))
                    .font(.app(.caption))
                    .foregroundStyle(.orange)
                    .padding(4)
            }
            if let error {
                Text(error).font(.app(.caption)).foregroundStyle(.red).padding(4)
            }
            ScrollViewReader { proxy in
                List(entries, id: \.rowID) { entry in
                    Text(entry.formatted)
                        .font(.app(.caption))
                        .foregroundStyle(entry.stream == .err ? .red : .primary)
                        .textSelection(.enabled)
                        .id(entry.rowID)
                }
                .onChange(of: entries.last?.rowID) { _, last in
                    if following, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("Logs")
        .onAppear(perform: search)
        .onDisappear { follow?.cancel() }
        .onChange(of: following) { _, on in
            follow?.cancel()
            guard on, let stream = model.followLogs(query) else { return }
            follow = Task {
                do {
                    for try await entry in stream {
                        entries.append(entry)
                        if entries.count > Self.maxLines { entries.removeFirst(entries.count - Self.maxLines) }
                    }
                } catch {
                    self.error = "\(error)"
                }
                following = false
            }
        }
    }

    private func search() {
        Task {
            do {
                if let result = try await model.searchLogs(query) {
                    entries = result.entries
                    gaps = result.gaps
                    error = nil
                }
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

extension LogEntry {
    var rowID: String { "\(node.rawValue)/\(seq)" }

    var formatted: String {
        "\(nodeTime.formatted(date: .omitted, time: .standard)) \(node)/\(service)[\(instance)] \(line)"
    }
}

struct ReleasesView: View {
    let model: ClusterModel
    @State private var service = ""
    @State private var version = ""
    @State private var releases: ClusterReleases?
    @State private var message: String?

    private var services: [String] { Array(Set(model.processes.map(\.service))).sorted() }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Service", selection: $service) {
                    ForEach(services, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 240)
                TextField("Version to deploy", text: $version).frame(width: 180)
                Button("Deploy") { run { try await model.deploy(service: service, version: version) } }
                    .disabled(service.isEmpty || version.isEmpty)
            }
            if let message {
                Text(message).font(.app(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(releases?.nodes ?? [], id: \.node.rawValue) { node in
                Section(node.node.rawValue) {
                    ForEach(node.releases.releases, id: \.sha12) { release in
                        HStack {
                            Image(systemName: release.sha12 == node.releases.current ? "checkmark.circle.fill" : "circle")
                            Text(release.sha12).font(.app(.body))
                            Text(release.createdAt.formatted()).foregroundStyle(.secondary)
                            Spacer()
                            if release.sha12 != node.releases.current {
                                Button("Roll back") {
                                    run { try await model.rollback(service: service, to: release.sha12, node: node.node.rawValue) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Releases")
        .onChange(of: service) { _, _ in reload() }
        .onAppear {
            if service.isEmpty { service = services.first ?? "" }
            reload()
        }
    }

    private func reload() {
        Task { releases = service.isEmpty ? nil : try? await model.releases(service: service) }
    }

    private func run(_ action: @escaping () async throws -> String) {
        Task {
            do {
                message = try await action()
            } catch {
                message = "\(error)"
            }
            reload()
        }
    }
}

#if DEBUG
#Preview("Nodes") { NodesView(model: .previewDegraded).frame(width: 1000, height: 500) }
#Preview("Processes") { ProcessesView(model: .previewHealthy).frame(width: 900, height: 500) }
#endif
