import SwiftUI
import TenderClient

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
                TextField("Name", text: $name, prompt: Text("Optional"))
                TextField("Head address", text: $head, prompt: Text("mac-1:7071"))
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
        }
        .formStyle(.grouped)
        .frame(width: fixedWidth ? 480 : nil)
        .frame(maxWidth: fixedWidth ? nil : 640)
        .task { await model.checkConnections() }
        .confirmationDialog("Remove \(removing?.name ?? "this connection")?", isPresented: isRemoving, presenting: removing) { connection in
            Button("Remove", role: .destructive) {
                Task { await model.removeConnection(connection.id) }
            }
        } message: { _ in
            Text("The app forgets its address and token. The head and its token aren't changed.")
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
