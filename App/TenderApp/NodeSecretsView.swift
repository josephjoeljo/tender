import SwiftUI
import TenderCore

/// A node's secrets sources, as its last heartbeat reported them: which accounts it fetches
/// with, for which services, and what's failing. Never a key or a value.
struct NodeSecretsCard: View {
    let secrets: NodeSecretsStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Secrets", systemImage: "key.fill").font(.headline)
                Spacer()
                if let secrets {
                    Text("\(secrets.localSecrets) local").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let secrets {
                if secrets.sources.isEmpty {
                    Text("No secrets manager attached. Services use only secrets set on the node.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("On the node: tender credentials set --file <key.json>")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(secrets.sources, id: \.name) { source in
                    SourceRow(source: source)
                }
            } else {
                Text("This node hasn't reported its secrets sources. It may run an older tenderd.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)) }
    }
}

private struct SourceRow: View {
    let source: SecretSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(source.name).font(.callout.weight(.semibold))
                if source.isDefault { RowBadge("DEFAULT", tint: .secondary) }
                Text(source.kind.uppercased()).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(state).font(.caption).foregroundStyle(tint)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                row("Account", source.account ?? "No key on the node")
                row("Project", source.project ?? "Named in each reference")
                row("Allowed", source.services?.joined(separator: ", ") ?? "Any service")
                row("Used by", source.usedBy.isEmpty ? "Nothing yet" : source.usedBy.joined(separator: ", "))
            }
            .font(.caption)
            if let problem = source.problem ?? source.lastError {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(source.problem != nil ? .red : .orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(2).textSelection(.enabled)
        }
    }

    private var state: String {
        if source.problem != nil { return "Unusable" }
        if source.failing > 0 { return "\(source.failing) of \(source.references) failing" }
        return source.references == 1 ? "1 secret" : "\(source.references) secrets"
    }

    private var icon: String {
        source.problem != nil ? "xmark.octagon.fill" : source.failing > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var tint: Color { source.problem != nil ? .red : source.failing > 0 ? .orange : .green }
}

#if DEBUG
#Preview("Secrets") {
    ScrollView {
        VStack(spacing: 16) {
            NodeSecretsCard(secrets: .preview)
            NodeSecretsCard(secrets: NodeSecretsStatus(localSecrets: 2))
            NodeSecretsCard(secrets: nil)
        }
        .padding()
    }
    .frame(width: 520, height: 700)
}
#endif
