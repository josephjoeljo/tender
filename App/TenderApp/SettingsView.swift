import SwiftUI

/// Head address and API token. The token also carries the CA fingerprint, which pins the
/// connection, and it's kept in the Keychain.
struct SettingsView: View {
    let model: ClusterModel
    @State private var head = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            if let connected = model.head {
                LabeledContent("Connected to", value: connected)
                Button("Disconnect") { model.disconnect() }
            } else {
                TextField("Head address", text: $head, prompt: Text("mac-1:7071"))
                SecureField("API token", text: $token)
                Text("Create one on the head: tender api-token create app --scope write")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect") {
                    busy = true
                    Task {
                        do {
                            try await model.connect(head: head, token: token)
                            error = nil
                            token = ""
                        } catch {
                            self.error = "\(error)"
                        }
                        busy = false
                    }
                }
                .disabled(busy || head.isEmpty || token.isEmpty)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
