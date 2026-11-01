import SwiftUI

/// Full dashboard: nodes, processes, logs, releases.
struct DashboardView: View {
    let model: ClusterModel

    enum Section: String, CaseIterable, Identifiable {
        case nodes = "Nodes", processes = "Processes", logs = "Logs", releases = "Releases"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .nodes: "desktopcomputer"
            case .processes: "gearshape.2"
            case .logs: "text.alignleft"
            case .releases: "shippingbox"
            }
        }
    }

    @State private var selection: Section? = .nodes

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ContentUnavailableView(
                selection?.rawValue ?? "Tender",
                systemImage: selection?.symbol ?? "leaf",
                description: Text("Coming in milestone 3.")
            )
        }
    }
}
