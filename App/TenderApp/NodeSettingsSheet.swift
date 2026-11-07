import SwiftUI
import TenderCore

/// A node's display name and labels. Saved on the node itself, through the head, so they
/// survive losing the head. Needs a write token.
struct NodeSettingsSheet: View {
    let model: ClusterModel
    let node: NodeSummary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var labels: [Row] = []
    @State private var error: String?
    @State private var saving = false

    struct Row: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name, prompt: Text(node.info.hostname ?? node.info.id.rawValue))
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown everywhere in place of the hostname. Leave it empty to use the hostname. The node's ID, \(node.info.id.rawValue), doesn't change.")
                }
                Section {
                    ForEach($labels) { $row in
                        HStack {
                            TextField("key", text: $row.key)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            TextField("value", text: $row.value)
                                .autocorrectionDisabled()
                            Button("Remove", systemImage: "minus.circle.fill", role: .destructive) {
                                labels.removeAll { $0.id == row.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Label", systemImage: "plus") { labels.append(Row(key: "", value: "")) }
                } header: {
                    Text("Labels")
                } footer: {
                    Text("key=value pairs for grouping now and placement later. Keys use lowercase letters, digits, '.', '_', '-' and '/'. Also `tender node label`.")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(node.info.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || update == NodeLabelsUpdate())
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .onAppear {
            let current = node.info.userLabels
            name = current[NodeLabels.nameKey] ?? ""
            labels = current.filter { $0.key != NodeLabels.nameKey }.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
        }
    }

    /// What changed against the node's current labels.
    private var update: NodeLabelsUpdate {
        let current = node.info.userLabels
        var wanted: [String: String] = [:]
        for row in labels {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { wanted[key] = row.value.trimmingCharacters(in: .whitespaces) }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { wanted[NodeLabels.nameKey] = trimmedName }
        return NodeLabelsUpdate(set: wanted.filter { current[$0.key] != $0.value },
                                remove: current.keys.filter { wanted[$0] == nil }.sorted())
    }

    private func save() {
        let update = self.update
        if let problem = NodeLabels.problem(with: update, current: node.info.userLabels) {
            error = problem
            return
        }
        saving = true
        Task {
            do {
                try await model.updateLabels(of: node, update)
                dismiss()
            } catch {
                self.error = "\(error)"
            }
            saving = false
        }
    }
}

#if DEBUG
#Preview("Node settings") {
    NodeSettingsSheet(model: .previewHealthy, node: ClusterModel.previewHealthy.nodes[0])
}
#endif
