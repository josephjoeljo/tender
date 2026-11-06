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

        /// The page TENDER_APP_OPEN names, in debug builds.
        static var atLaunch: Section? {
            #if DEBUG
            ProcessInfo.processInfo.environment["TENDER_APP_OPEN"].flatMap { name in
                allCases.first { $0.rawValue.lowercased() == name.lowercased() }
            }
            #else
            nil
            #endif
        }
    }

    @State private var selection: Section? = Section.atLaunch ?? .nodes

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
            .font(.body)
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
    @State private var removing: NodeSummary?
    @AppStorage("nodesLayout") private var layout: NodesLayout = .list

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch layout {
                case .list:
                    List(model.nodes) { node in
                        ExpandableRow(isExpanded: expanded.contains(node.id), toggle: { expanded.toggle(node.id) }) {
                            NodeTrackRow(node: node, open: { path.append(node.id) }, remove: { removing = node })
                        } detail: {
                            NodeStatsPanel(node: node)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in RowLayout.textLeading }
                    }
                    .listStyle(.inset)
                case .bento:
                    NodesBentoView(nodes: model.nodes, open: { path.append($0.id) }, remove: { removing = $0 })
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
        .confirmationDialog("Remove \(removing?.info.displayName ?? "this node")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { node in
            Button("Remove Node", role: .destructive) {
                Task { await model.removeNode(node, force: node.up) }
            }
        } message: { node in
            Text("""
                Deletes \(node.info.displayName) (\(node.info.id.rawValue)) from the head and revokes its certificate. \
                Its processes keep running, but it can't rejoin without a new join token.\(node.up ? " It is up right now." : "")
                """)
        }
    }
}

extension NodeSummary: @retroactive Identifiable {
    public var id: String { info.id.rawValue }
}

extension InstanceStatus: @retroactive Identifiable {
    public var id: String { rowID }
}

/// Processes grouped by node, with the selected one in the inspector beside the list.
/// Double-click a process, or use the inspector's button, to open it in its own window.
struct ProcessesView: View {
    let model: ClusterModel
    @State private var selection: String?
    @State private var showsInspector = true
    @State private var collapsed: Set<String> = []
    @AppStorage("processInspectorTab") private var tab: InspectorTab = .details
    @Environment(\.openWindow) private var openWindow

    private var selected: InstanceStatus? { model.processes.first { $0.id == selection } }

    /// Nodes in the order the Nodes page shows them, each with its processes.
    private var groups: [(node: NodeID, processes: [InstanceStatus])] {
        let byNode = Dictionary(grouping: model.processes, by: \.node)
        let order = model.nodes.map(\.info.id) + byNode.keys.filter { id in !model.nodes.contains { $0.info.id == id } }
            .sorted { $0.rawValue < $1.rawValue }
        return order.compactMap { node in
            byNode[node].map { (node, $0.sorted { ($0.service, $0.instance) < ($1.service, $1.instance) }) }
        }
    }

    var body: some View {
        let counts = Dictionary(model.processes.map { ("\($0.node.rawValue)/\($0.service)", 1) }, uniquingKeysWith: +)
        let compact = showsInspector
        List(selection: $selection) {
            ForEach(groups, id: \.node) { group in
                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(group.node.rawValue) },
                                                    set: { if $0 { collapsed.remove(group.node.rawValue) } else { collapsed.insert(group.node.rawValue) } })) {
                    ForEach(group.processes) { process in
                        ProcessTrackRow(process: process, model: model,
                                        showsInstance: counts["\(process.node.rawValue)/\(process.service)", default: 0] > 1,
                                        compact: compact)
                            .tag(process.id)
                    }
                } label: {
                    NodeGroupLabel(node: model.nodes.first { $0.info.id == group.node },
                                   name: model.name(of: group.node), processes: group.processes)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            for id in ids {
                if let process = model.processes.first(where: { $0.id == id }) { openWindow(id: "process", value: ProcessRef(process)) }
            }
        }
        .overlay {
            if model.processes.isEmpty {
                ContentUnavailableView("No Processes", systemImage: "gearshape.2",
                                       description: Text("Start one with tender start, or apply a service file."))
            }
        }
        .navigationTitle("Processes")
        .navigationSubtitle("\(model.processes.filter { $0.state == .running }.count) running")
        .inspector(isPresented: $showsInspector) {
            Group {
                if let selected {
                    let ref = ProcessRef(selected)
                    ProcessInspector(model: model, ref: ref, tab: $tab) { openWindow(id: "process", value: ref) }
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                           description: Text("Pick a process to see its details, config and logs."))
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .onAppear {
            if selection == nil { selection = groups.first?.processes.first?.id }
        }
    }
}

/// The row a node's processes fold under, like a compose project in a container app.
private struct NodeGroupLabel: View {
    let node: NodeSummary?
    let name: String
    let processes: [InstanceStatus]

    var body: some View {
        let running = processes.filter { $0.state == .running }.count
        let crashed = processes.filter { $0.state == .crashed }.count
        HStack(spacing: 10) {
            Image(systemName: node?.info.isHead == true ? "crown.fill" : "desktopcomputer")
                .foregroundStyle(node?.up == false ? Color.secondary : node?.info.isHead == true ? .orange : .blue)
                .frame(width: 20)
            Text(name).font(.headline)
            if node?.up == false { RowBadge("DOWN", tint: .red) }
            if crashed > 0 { RowBadge("\(crashed) CRASHED", tint: .red) }
            Spacer()
            Text("\(running) of \(processes.count) running")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Search plus live follow. Lines stay bounded so that a busy service can't grow the view forever.
struct LogsView: View {
    let model: ClusterModel
    private static let maxLines = 5_000

    @State private var text = ""
    @State private var services: Set<String> = []
    @State private var nodes: Set<String> = []
    @State private var stream = "all"
    @State private var window = 3600.0
    @State private var entries: [LogEntry] = []
    @State private var gaps: [LogGap] = []
    @State private var following = false
    @State private var started = false
    @State private var error: String?
    @State private var follow: Task<Void, Never>?

    private var query: LogQuery {
        // The API filters on one value; several are narrowed client-side by `visible`.
        LogQuery(service: services.count == 1 ? services.first : nil, node: nodes.count == 1 ? nodes.first : nil,
                 stream: LogLine.Stream(rawValue: stream), since: Date().addingTimeInterval(-window),
                 text: text.isEmpty ? nil : text, limit: 1000)
    }

    /// Node IDs, sorted by the name the menu shows.
    private var nodeOptions: [String] {
        Set(model.nodes.map(\.info.id.rawValue)).union(nodes).sorted {
            model.name(of: NodeID($0)).localizedStandardCompare(model.name(of: NodeID($1))) == .orderedAscending
        }
    }
    private var serviceOptions: [String] { Set(model.processes.map(\.service)).union(services).sorted() }

    private func accepts(_ entry: LogEntry) -> Bool {
        (services.isEmpty || services.contains(entry.service)) && (nodes.isEmpty || nodes.contains(entry.node.rawValue))
    }

    /// `label` turns an option into what the menu shows; the selection keeps the raw value (a node's ID).
    private func filterMenu(_ title: String, options: [String], selection: Binding<Set<String>>,
                            label: @escaping (String) -> String = { $0 }) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Toggle(label(option), isOn: Binding(
                    get: { selection.wrappedValue.contains(option) },
                    set: { on in
                        if on { selection.wrappedValue.insert(option) } else { selection.wrappedValue.remove(option) }
                        search()
                    }))
            }
            if !selection.wrappedValue.isEmpty {
                Divider()
                Button("Clear") { selection.wrappedValue = []; search() }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? "All \(title)" : "\(title) (\(selection.wrappedValue.count))")
        }
        .frame(width: 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $text).onSubmit(search)
                filterMenu("services", options: serviceOptions, selection: $services)
                filterMenu("nodes", options: nodeOptions, selection: $nodes) { model.name(of: NodeID($0)) }
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
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(4)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(4)
            }
            ScrollViewReader { proxy in
                List(entries, id: \.rowID) { entry in
                    Text(entry.formatted)
                        .font(.caption)
                        .foregroundStyle(entry.stream == .err ? .red : .primary)
                        .textSelection(.enabled)
                        .id(entry.rowID)
                }
                .onChange(of: entries.first?.rowID) { _, first in
                    if following, let first { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
        .navigationTitle("Logs")
        .task {
            guard !started else { return }
            started = true
            await runSearch()
            following = true
        }
        .onDisappear { follow?.cancel() }
        .onChange(of: following) { _, on in
            follow?.cancel()
            guard on, let stream = model.followLogs(query) else { return }
            follow = Task {
                do {
                    for try await entry in stream {
                        guard accepts(entry), !entries.contains(where: { $0.rowID == entry.rowID }) else { continue }
                        entries.insert(entry, at: 0)
                        if entries.count > Self.maxLines { entries.removeLast(entries.count - Self.maxLines) }
                    }
                } catch {
                    self.error = "\(error)"
                }
                following = false
            }
        }
    }

    private func search() { Task { await runSearch() } }

    /// Newest first, to match the follow stream that inserts at the top.
    private func runSearch() async {
        do {
            if let result = try await model.searchLogs(query) {
                entries = result.entries.filter(accepts).reversed()
                gaps = result.gaps
                error = nil
            }
        } catch {
            self.error = "\(error)"
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
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(releases?.nodes ?? [], id: \.node.rawValue) { node in
                Section(model.name(of: node.node)) {
                    ForEach(node.releases.releases, id: \.sha12) { release in
                        HStack {
                            Image(systemName: release.sha12 == node.releases.current ? "checkmark.circle.fill" : "circle")
                            Text(release.sha12).font(.body)
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
#Preview("Processes") { NavigationStack { ProcessesView(model: .previewHealthy) }.frame(width: 1000, height: 600) }
#endif
