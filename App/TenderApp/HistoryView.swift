import SwiftUI
import TenderClient
import TenderCore

/// The head's audit log: who changed what, when, and whether it worked. Failures are
/// counted at the top, so trouble shows before you read the list.
struct HistoryView: View {
    let model: ClusterModel
    @AppStorage("historyWindow") private var window: Double = 86400
    @AppStorage("historyFailedOnly") private var failedOnly = false
    @State private var about = ""
    @State private var list: AuditList?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            if let list {
                if list.failures > 0 {
                    Label("\(list.failures) of \(list.records.count) changes failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if list.records.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "clock.arrow.circlepath",
                                           description: Text("Nothing was changed in this window."))
                }
                ForEach(Array(list.records.enumerated()), id: \.offset) { _, record in
                    HistoryRow(record: record, nodeName: record.node.map { model.name(of: NodeID($0)) })
                }
                if list.truncated {
                    Text("Only the newest \(list.records.count) are shown. Narrow the window or the search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if loading {
                ProgressView()
            }
        }
        .listStyle(.inset)
        .navigationTitle("History")
        .searchable(text: $about, prompt: "Service, secret or node")
        .onSubmit(of: .search) { reload() }
        .toolbar {
            ToolbarItem {
                Picker("Window", selection: $window) {
                    Text("1 hour").tag(3600.0)
                    Text("1 day").tag(86400.0)
                    Text("7 days").tag(7 * 86400.0)
                    Text("30 days").tag(30 * 86400.0)
                }
                .help("How far back to look")
            }
            ToolbarItem {
                Toggle("Failed Only", systemImage: "exclamationmark.triangle", isOn: $failedOnly)
                    .help("Show only changes that failed")
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { reload() }
                    .keyboardShortcut("r")
            }
        }
        .refreshable { await load() }
        .task(id: "\(window) \(failedOnly) \(model.head ?? "")") { await load() }
        .onChange(of: about) { _, new in if new.isEmpty { reload() } }
    }

    private func reload() { Task { await load() } }

    private func load() async {
        loading = true
        defer { loading = false }
        let query = AuditQuery(since: Date().addingTimeInterval(-window), limit: 500,
                               about: about.isEmpty ? nil : about, failedOnly: failedOnly)
        do {
            list = try await model.history(query)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

private struct HistoryRow: View {
    let record: AuditRecord
    let nodeName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(record.succeeded ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.action.capitalizedFirst).fontWeight(.medium)
                    if let target = record.target { Text(target).foregroundStyle(.secondary) }
                    if !record.succeeded { RowBadge("HTTP \(record.status)", tint: .red) }
                }
                Text([record.who, nodeName.map { "on \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(record.time, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(record.time.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.vertical, 2)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

#if DEBUG
#Preview("History") { NavigationStack { HistoryView(model: .previewHealthy) }.frame(width: 800, height: 500) }
#endif
