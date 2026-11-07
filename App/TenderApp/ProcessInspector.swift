import SwiftUI
import TenderClient
import TenderCore

// The panel beside the process list, and the window a process pops out into.
// Details: what the process is doing now. Info: the spec it was started from,
// with its environment. Logs: its recent lines, followed live.

/// Which process an inspector or window shows. Kept by value, so a window outlives a
/// refresh that replaces the `InstanceStatus` it was opened from.
struct ProcessRef: Codable, Hashable {
    var node: String
    var service: String
    var instance: Int

    init(_ process: InstanceStatus) {
        node = process.node.rawValue
        service = process.service
        instance = process.instance
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info", stats = "Stats", logs = "Logs"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .stats: "gauge.with.dots.needle.33percent"
        case .logs: "text.alignleft"
        }
    }
}

extension ClusterModel {
    func process(_ ref: ProcessRef) -> InstanceStatus? {
        processes.first { $0.node.rawValue == ref.node && $0.service == ref.service && $0.instance == ref.instance }
    }
}

extension InstanceStatus {
    /// What `launchctl print` knows it by.
    var launchdLabel: String { adopted ? service : "com.olympsis.tender.svc.\(service).\(instance)" }
}

struct ProcessInspector: View {
    let model: ClusterModel
    let ref: ProcessRef
    @Binding var tab: InspectorTab
    /// Opens the process in a window of its own. Nil when this already is that window.
    var popOut: (() -> Void)?

    var body: some View {
        Group {
            if let process = model.process(ref) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ProcessHeader(process: process, model: model)
                        switch tab {
                        case .info:
                            ProcessFactsSection(process: process, model: model)
                            ProcessDescriptorsSection(process: process, model: model)
                            ProcessConfigSection(process: process, model: model)
                        case .stats:
                            ProcessStatsPanel(process: process, node: model.nodes.first { $0.info.id == process.node },
                                              compact: true, showsFacts: false)
                        case .logs: ProcessLogsTab(model: model, ref: ref)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Process Gone", systemImage: "questionmark.square.dashed",
                                       description: Text("\(ref.service) isn't on \(model.name(of: NodeID(ref.node))) anymore."))
            }
        }
        .toolbar {
            // Centres the tab menu over the inspector, with the pop-out at its far edge.
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $tab) {
                        ForEach(InspectorTab.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    // Our own chevron: the menu's indicator pads the capsule more than the round buttons beside it.
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
                .menuIndicator(.hidden)
                .help("Switch between info, stats and logs")
            }
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            if let popOut {
                ToolbarItem {
                    Button("Open in New Window", systemImage: "arrow.up.forward.app", action: popOut)
                        .help("Open this process in its own window")
                }
            }
        }
    }
}

/// Artwork, name and where it runs, with the actions you reach for most.
private struct ProcessHeader: View {
    let process: InstanceStatus
    let model: ClusterModel

    var body: some View {
        let kind = process.resolvedKind
        HStack(spacing: 12) {
            RowArtwork(symbol: kind.symbol, tint: kind.tint, active: process.state == .running)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.service).font(.title3.weight(.semibold)).lineLimit(1).textSelection(.enabled)
                    if process.adopted { RowBadge("ADOPTED") }
                }
                Text("\(kind.title) on \(model.name(of: process.node))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ControlGroup {
                if process.state == .running {
                    Button("Stop", systemImage: "stop.fill") { perform(.stop) }.help("Stop")
                } else {
                    Button("Start", systemImage: "play.fill") { perform(.start) }.help("Start")
                }
                Button("Restart", systemImage: "arrow.clockwise") { perform(.restart) }.help("Restart")
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
            .fixedSize()
        }
    }

    private func perform(_ action: ClusterModel.Action) {
        Task { await model.perform(action, on: process) }
    }
}

// MARK: Info

/// What it is and how it's doing, like the name, ID and status at the top of a container.
private struct ProcessFactsSection: View {
    let process: InstanceStatus
    let model: ClusterModel

    var body: some View {
        InspectorCard(rows: [
            ("Status", status),
            ("Node", model.name(of: process.node)),
            ("PID", process.pid.map(String.init) ?? StatFormat.dash),
            ("Instance", "\(process.instance)"),
            ("Release", process.release ?? StatFormat.dash),
            ("Restarts", "\(process.restarts)"),
            ("Last exit", process.lastExitCode.map(String.init) ?? StatFormat.dash),
        ])
        InspectorCard(rows: [("Label", process.launchdLabel)])
    }

    private var status: String {
        switch process.state {
        case .running: process.uptime.map { "Up \(StatFormat.duration($0))" } ?? "Running"
        case .crashed: "Crashed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .unknown: "Unknown"
        }
    }
}

/// The ports it listens on, the files it has open and its descriptors by kind, read from
/// the node on demand and refreshed while shown.
private struct ProcessDescriptorsSection: View {
    let process: InstanceStatus
    let model: ClusterModel
    private static let filesShown = 50

    @State private var result: ProcessDescriptors?
    @State private var error: String?
    @State private var showsAllFiles = false

    var body: some View {
        Group {
            if process.state != .running {
                InspectorSection("Ports") {
                    note("Not running, so it holds no ports or files.")
                }
            } else {
                InspectorTable(title: "Ports", columns: ("Address", "Protocol"),
                               rows: (result?.ports ?? []).map { ($0.endpoint, $0.proto.rawValue.uppercased()) },
                               empty: placeholder("Not listening on any port"), valueWidth: 70)
                let files = result?.files ?? []
                let total = files.count + (result?.filesOmitted ?? 0)
                InspectorTable(title: "Open Files", columns: ("Path", "Mode"),
                               rows: (showsAllFiles ? files : Array(files.prefix(Self.filesShown))).map { ($0.path, $0.mode.title) },
                               empty: placeholder("No open files"), valueWidth: 80) {
                    if files.count > Self.filesShown {
                        Button(showsAllFiles ? "Show Fewer" : "Show All \(total)") { showsAllFiles.toggle() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    } else if total > 0 {
                        Text("\(total)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let result {
                    InspectorCard(title: "File Descriptors",
                                  rows: [("Total", "\(result.total)")] + result.counts.map { ($0.kind.title, "\($0.count)") })
                    if result.unreadable > 0 {
                        note("\(result.unreadable) child \(result.unreadable == 1 ? "process" : "processes") couldn't be read.")
                    }
                }
            }
        }
        .task(id: "\(process.id)/\(process.pid ?? 0)") { await refresh() }
    }

    private func placeholder(_ empty: String) -> String {
        error ?? (result == nil ? "Loading…" : empty)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    /// Every 15 seconds while shown. A read is a libproc walk on the node, so not faster.
    private func refresh() async {
        result = nil
        error = nil
        guard process.state == .running else { return }
        while !Task.isCancelled {
            do {
                result = try await model.descriptors(for: process)
                error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = "Couldn't read: \(error)"
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

extension OpenFile.Mode {
    var title: String {
        switch self {
        case .read: "Read"
        case .write: "Write"
        case .readWrite: "Read/Write"
        }
    }
}

extension DescriptorCount.Kind {
    var title: String {
        switch self {
        case .file: "Files"
        case .socket: "Sockets"
        case .pipe: "Pipes"
        case .kqueue: "Kqueues"
        case .other: "Other"
        }
    }
}

/// The spec it was started from: program, environment, secret files and log paths.
private struct ProcessConfigSection: View {
    let process: InstanceStatus
    let model: ClusterModel
    @State private var revealed = false

    var body: some View {
        Group {
            if let spec = model.spec(for: process) {
                serviceConfig(spec)
            } else if let adopted = model.adoptedItem(for: process) {
                InspectorCard(title: "Adopted Job", rows: [
                    ("Label", adopted.label),
                    ("Log path", adopted.logPath ?? "From the job's plist"),
                ])
                Text("Tender didn't create this job, so its program and environment live in its own plist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.specsError {
                InspectorSection("Config") {
                    Label("Reading config needs a write token, since it can hold values from an env_file. \(error)",
                          systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.specs == nil {
                InspectorSection("Config") { ProgressView().frame(maxWidth: .infinity) }
            } else {
                InspectorSection("Config") {
                    Text("\(model.name(of: process.node)) didn't report a spec for \(process.service).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: process.id) { await model.loadSpecs() }
    }

    @ViewBuilder
    private func serviceConfig(_ spec: ServiceSpec) -> some View {
        InspectorCard(title: "Program", rows: [
            ("Program", program(spec.program)),
            ("Arguments", spec.arguments.isEmpty ? "None" : spec.arguments.joined(separator: " ")),
            ("Working directory", spec.workingDirectory ?? "Default"),
            ("User", spec.user),
            ("Instances", "\(spec.instances)"),
        ])
        InspectorTable(title: "Environment", columns: ("Key", "Value"),
                       rows: spec.environment.sorted { $0.key < $1.key }.map { ($0.key, masked($0.value)) },
                       empty: "No environment variables") {
            if spec.environment.values.contains(where: { !Self.isReference($0) }) {
                Button(revealed ? "Hide Values" : "Show Values", systemImage: revealed ? "eye.slash" : "eye") {
                    revealed.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(revealed ? "Hide values" : "Show values")
            }
        }
        if !spec.secretFiles.isEmpty {
            InspectorTable(title: "Secret Files", columns: ("Path", "Secret"),
                           rows: spec.secretFiles.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                           empty: "")
        }
        if let logs = spec.logPaths {
            InspectorCard(title: "Log Files", rows: [
                ("stdout", logs.stdout ?? "Default"),
                ("stderr", logs.stderr ?? "Default"),
            ])
        }
    }

    private func program(_ source: ProgramSource) -> String {
        switch source {
        case .executable(let path): path
        case .release(let sha12): "Release \(sha12)"
        }
    }

    /// `${secret:…}` references say nothing secret, so they always show.
    private static func isReference(_ value: String) -> Bool { value.hasPrefix("${secret:") && value.hasSuffix("}") }

    private func masked(_ value: String) -> String {
        revealed || Self.isReference(value) ? value : String(repeating: "•", count: min(max(value.count, 4), 12))
    }
}

// MARK: Logs

private struct ProcessLogsTab: View {
    let model: ClusterModel
    let ref: ProcessRef
    private static let maxLines = 1_000

    @State private var entries: [LogEntry] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if entries.isEmpty {
                Text(loaded ? "No lines in the last day." : "Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.rowID) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.nodeTime.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Text(entry.line)
                            .foregroundStyle(entry.stream == .err ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
        }
        .task(id: ref) { await run() }
    }

    private var query: LogQuery {
        LogQuery(service: ref.service, node: ref.node, since: Date().addingTimeInterval(-86_400), limit: 300)
    }

    /// The last day's lines, newest first, then follows until the tab goes away.
    private func run() async {
        entries = []
        loaded = false
        do {
            if let result = try await model.searchLogs(query) {
                entries = result.entries.filter { $0.instance == ref.instance }.reversed()
            }
            error = nil
        } catch {
            self.error = "\(error)"
        }
        loaded = true
        guard let stream = model.followLogs(query) else { return }
        do {
            for try await entry in stream where entry.instance == ref.instance {
                guard !entries.contains(where: { $0.rowID == entry.rowID }) else { continue }
                entries.insert(entry, at: 0)
                if entries.count > Self.maxLines { entries.removeLast(entries.count - Self.maxLines) }
            }
        } catch is CancellationError {
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: Cards

/// A titled group, like a section of System Settings.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(_ title: String?, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    accessory
                }
                .padding(.horizontal, 4)
            }
            content
        }
    }
}

/// Label on the left, value on the right, in one rounded card.
struct InspectorCard: View {
    var title: String?
    let rows: [(String, String)]
    /// Longer values go on a line of their own.
    private static let stackAfter = 24

    var body: some View {
        InspectorSection(title) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    Group {
                    if row.1.count > Self.stackAfter {
                        // Paths, labels and argument lists read better whole, under their name.
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.0).fontWeight(.medium)
                            Text(row.1)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.0).fontWeight(.medium)
                            Spacer(minLength: 8)
                            Text(row.1)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .cardBackground()
        }
    }
}

/// Two columns under a header row, like the port and mount tables in a container app.
struct InspectorTable<Accessory: View>: View {
    let title: String
    let columns: (String, String)
    let rows: [(String, String)]
    let empty: String
    /// A fixed width for the second column, so a short one (mode, protocol) leaves the first
    /// (a path) the room. Nil splits the width evenly.
    let valueWidth: CGFloat?
    let accessory: Accessory

    init(title: String, columns: (String, String), rows: [(String, String)], empty: String, valueWidth: CGFloat? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.empty = empty
        self.valueWidth = valueWidth
        self.accessory = accessory()
    }

    var body: some View {
        InspectorSection(title) {
            VStack(spacing: 0) {
                row(columns.0, columns.1)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, -2)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                    Divider().padding(.leading, 12)
                    row(entry.0, entry.1)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                if rows.isEmpty {
                    Divider().padding(.leading, 12)
                    Text(empty)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
            }
            .cardBackground()
        } accessory: {
            accessory
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Paths get a second line before they're shortened.
                .lineLimit(valueWidth == nil ? 1 : 2)
                .truncationMode(.middle)
            Text(value)
                .foregroundStyle(.secondary)
                .frame(minWidth: valueWidth, maxWidth: valueWidth ?? .infinity, alignment: .leading)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension View {
    func cardBackground() -> some View {
        background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Window

/// A process broken out of the dashboard into a window of its own.
struct ProcessWindow: View {
    let model: ClusterModel
    let ref: ProcessRef?
    @State private var tab: InspectorTab = .info

    var body: some View {
        if let ref {
            ProcessInspector(model: model, ref: ref, tab: $tab)
                .navigationTitle(ref.service)
                .navigationSubtitle(model.name(of: NodeID(ref.node)))
                .frame(minWidth: 420, idealWidth: 520, minHeight: 480, idealHeight: 680)
        } else {
            ContentUnavailableView("No Process", systemImage: "gearshape.2")
        }
    }
}

#if DEBUG
extension SpecList {
    /// A spec for every non-adopted process, so the Info tab has something to show.
    static func preview(_ processes: [InstanceStatus]) -> SpecList {
        let byNode = Dictionary(grouping: processes, by: \.node)
        return SpecList(nodes: byNode.map { node, processes in
            NodeSpecs(node: node, services: Set(processes.map(\.service)).sorted().map { service in
                ServiceSpec(name: service, program: .release(sha12: "3f9a1c2b7d4e"),
                            arguments: ["--port", "8080"],
                            environment: ["PORT": "8080", "MONGO_URI": "mongodb://localhost:27017/olympsis",
                                          "LOG_LEVEL": "info", "JWT_SECRET": "${secret:JWT_SECRET}"],
                            workingDirectory: "/opt/tender/releases/\(service)",
                            secretFiles: ["/etc/olympsis/gcp.json": "shared/GCP_KEY"])
            })
        })
    }
}

extension ProcessDescriptors {
    static func preview(_ process: InstanceStatus) -> ProcessDescriptors {
        let pid = process.pid ?? 4242
        return ProcessDescriptors(
            service: process.service, instance: process.instance, node: process.node, pid: pid,
            ports: [ListeningPort(proto: .tcp, address: "*", port: 8080, pid: pid),
                    ListeningPort(proto: .tcp, address: "127.0.0.1", port: 9090, pid: pid + 1)],
            files: [OpenFile(fd: 3, path: "/opt/tender/releases/\(process.service)/3f9a1c2b7d4e/\(process.service)", mode: .read, pid: pid),
                    OpenFile(fd: 4, path: "/var/log/tender/\(process.service).0.out.log", mode: .write, pid: pid),
                    OpenFile(fd: 7, path: "/Users/joel/Library/Application Support/olympsis/cache.db", mode: .readWrite, pid: pid + 1)],
            counts: [DescriptorCount(kind: .socket, count: 14), DescriptorCount(kind: .file, count: 3),
                     DescriptorCount(kind: .pipe, count: 4), DescriptorCount(kind: .kqueue, count: 1)])
    }
}

#Preview("Inspector") {
    @Previewable @State var tab = InspectorTab.info
    let model = ClusterModel.previewHealthy
    ProcessInspector(model: model, ref: ProcessRef(model.processes[0]), tab: $tab)
        .frame(width: 380, height: 700)
}
#endif
