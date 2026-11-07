import SwiftUI
import TenderClient
import TenderCore

/// Shows the commands that join a new Mac, then waits for it to show up in the list.
/// Join tokens are made on the head itself: it only issues them on its local socket.
struct AddNodeSheet: View {
    let model: ClusterModel
    @Environment(\.dismiss) private var dismiss

    /// Nodes already in the cluster when the sheet opened, so a new one can be spotted.
    @State private var known: Set<String> = []

    private var joined: [NodeSummary] { model.nodes.filter { !known.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: RowLayout.spacing) {
                RowArtwork(symbol: "plus", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Node").font(.title3.bold())
                    Text("Join another Mac to this cluster.").foregroundStyle(.secondary)
                }
            }

            step(1, "On the head, create a join token. It works once and expires after 15 minutes:") {
                CommandBox(command: "sudo tender token create")
            }
            step(2, "On the new Mac, install the daemon:") {
                CommandBox(command: "sudo tender daemon install --system")
            }
            step(3, "Then join it with the token:") {
                CommandBox(command: "sudo tender join \(model.head ?? "<head-address>") --token <token>")
            }
            Text("The new Mac gets a UUID as its node ID the first time its daemon runs. Its hostname is shown as its name and can change freely.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                if let node = joined.first {
                    Label("\(node.info.displayName) joined", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the node to join…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(joined.isEmpty ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 520)
        #endif
        .onAppear { known = Set(model.nodes.map(\.id)) }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)")
            content()
        }
    }
}

/// A command in monospaced type with a copy button.
private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(command)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
