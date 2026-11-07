import SwiftUI
import TenderClient
import TenderCore

/// The heads the app can talk to, one of them active. A token also carries the CA
/// fingerprint, which pins the connection, and it's kept in the Keychain.
struct SettingsView: View {
    let model: ClusterModel
    /// The Settings window sizes itself to the form; the dashboard gives it the detail column.
    var fixedWidth = true
    @State private var name = ""
    @State private var head = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false
    @State private var removing: SavedConnection?
    /// A shorter retention waiting for confirmation, since it deletes history right away.
    @State private var lowering: HistoryRetentionUpdate?

    var body: some View {
        Form {
            Section("Connections") {
                if model.connections.connections.isEmpty {
                    Text("No connections yet.").foregroundStyle(.secondary)
                }
                ForEach(model.connections.connections) { connection in
                    row(connection)
                }
                if let savedError = model.savedConnectionError {
                    Text(savedError).foregroundStyle(.red).font(.caption)
                }
            }
            Section("Add a connection") {
                // iOS forms show only the prompt, so it names the field there.
                TextField("Name", text: $name, prompt: Text(Self.prompt("Name", "Optional")))
                TextField("Head address", text: $head, prompt: Text(Self.prompt("Head address", "mac-1:7071")))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("API token", text: $token)
                Text("Create one on the head: tender api-token create app --scope write")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add and Connect") { add() }
                    .disabled(busy || head.isEmpty || token.isEmpty)
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            if model.head != nil { historySection }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: fixedWidth ? 480 : nil)
        .frame(maxWidth: fixedWidth ? nil : 640)
        #endif
        .task { await model.checkConnections() }
        .task(id: model.connections.activeID) { await model.loadHistoryRetention(force: true) }
        .confirmationDialog("Delete older history?", isPresented: isLowering, presenting: lowering) { update in
            Button("Keep Less History", role: .destructive) {
                Task { await model.setHistoryRetention(update) }
            }
        } message: { update in
            Text("The head deletes \(update.nodeDays != nil ? "node" : "process") history older than \(keptFor(update.nodeDays ?? update.processDays)) now. It can't be brought back.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this connection")?", isPresented: isRemoving, presenting: removing) { connection in
            Button("Remove", role: .destructive) {
                Task { await model.removeConnection(connection.id) }
            }
        } message: { _ in
            Text("The app forgets its address and token. The head and its token aren't changed.")
        }
    }

    private static func prompt(_ label: String, _ example: String) -> String {
        #if os(macOS)
        example
        #else
        "\(label) (\(example))"
        #endif
    }

    private var isLowering: Binding<Bool> {
        Binding(get: { lowering != nil }, set: { if !$0 { lowering = nil } })
    }

    /// Choices for how long to keep history, plus the head's current value if it's another.
    private static let retentionChoices: [(label: String, days: Int)] = [
        ("1 day", 1), ("7 days", 7), ("30 days", 30), ("90 days", 90), ("6 months", HistoryRetention.defaultDays),
        ("1 year", 365), ("2 years", 730),
    ]

    @ViewBuilder
    private var historySection: some View {
        Section {
            if let retention = model.historyRetention {
                retentionPicker("Node history", days: retention.nodeDays) { HistoryRetentionUpdate(nodeDays: $0) }
                retentionPicker("Process history", days: retention.processDays) { HistoryRetentionUpdate(processDays: $0) }
            }
            if let error = model.historyRetentionError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("History")
        } footer: {
            Text("How long the head keeps stats charts. Minutes are kept for 2 days and 15-minute points for 35, then hourly points for the rest. Windows longer than this are hidden. Needs a write token; also `tender retention`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func retentionPicker(_ title: String, days: Int,
                                 update: @escaping (Int) -> HistoryRetentionUpdate) -> some View {
        var choices = Self.retentionChoices
        if !choices.contains(where: { $0.days == days }) {
            choices.append((keptFor(days), days))
            choices.sort { $0.days < $1.days }
        }
        let selection = Binding(get: { days }, set: { newDays in
            guard newDays != days else { return }
            if newDays < days { lowering = update(newDays) } else { Task { await model.setHistoryRetention(update(newDays)) } }
        })
        return Picker(title, selection: selection) {
            ForEach(choices, id: \.days) { Text($0.label).tag($0.days) }
        }
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private func row(_ connection: SavedConnection) -> some View {
        let active = connection.id == model.connections.activeID
        return HStack {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading) {
                Text(connection.name)
                Text(connection.context.head).font(.caption).foregroundStyle(.secondary)
                if active, let headName = model.headNodeName {
                    Label {
                        Text("Head: \(headName)")
                    } icon: {
                        Image(systemName: "crown.fill").foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                status(of: connection)
            }
            Spacer()
            if !active {
                Button("Use") {
                    Task { await model.switchToConnection(connection.id) }
                }
            }
            Button("Remove") { removing = connection }
        }
        #if os(iOS)
        // A form row would otherwise fire both buttons on any tap.
        .buttonStyle(.borderless)
        #endif
    }

    @ViewBuilder
    private func status(of connection: SavedConnection) -> some View {
        switch model.connectionStatus[connection.id] {
        case .reachable:
            Text("Reachable").font(.caption).foregroundStyle(.green)
        case .unreachable(let reason):
            Text(reason).font(.caption).foregroundStyle(.red)
        case .checking, nil:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        busy = true
        Task {
            do {
                try await model.addConnection(name: name, head: head, token: token)
                error = nil
                name = ""
                head = ""
                token = ""
            } catch {
                self.error = "\(error)"
            }
            busy = false
        }
    }
}
